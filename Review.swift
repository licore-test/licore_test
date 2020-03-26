//
//  Review.swift
//  App
//
//  Created by Oguz Sutanrikulu on 24.12.19.
//



import Vapor
import SwiftLintFramework

class Review {
    func runReview(project: LicoreProject, repository: Repository, pullRequest: PullRequest, req: Request) {
        logger.info("Review process started...")
        
        let shortHash = String(pullRequest.latestCommit.prefix(8))
        let swiftLint = SwiftLint()
        
        if self.directoryExists(pullRequest: pullRequest) {
            logger.info("Deleting existing directory...")
            self.deleteDirectory(pullRequest: pullRequest)
        }
        
        logger.info("Deleting older Comments...")
        project.sourceControlService(req: req).map { sourceControlService in
            
            guard let sourceControlService = sourceControlService else {
                logger.error("Source Control Service could not be loaded!")
                return
            }
            
            sourceControlService.deleteAllComments(repositoryName: repository.name, pullRequestId: pullRequest.scmId, req: req)
            
            logger.info("Getting former tasks...")
            var formerTasks: [Task?] = []
            sourceControlService.getTasks(repositoryName: repository.name, pullRequest: pullRequest, req: req).whenSuccess { tasks in
                formerTasks = tasks
                
                logger.info("Creating new directory...")
                self.createDirectory(pullRequest: pullRequest)
                
                logger.info("Downloading sources...")
                sourceControlService.downloadSources(pullRequest: pullRequest, req: req) {
                    
                    logger.info("Unzipping...")
                    self.unzipSources(fileName: "sourceFiles", fileExtension: ".zip", pullRequest: pullRequest)
                    
                    logger.info("Linting...")
                    let violations = swiftLint.runLinting(for: shortHash, with: project.rules)
                    var comments: ([StyleViolation], [(StyleViolation, Segment)])?
                    
                    logger.info("Getting the Diff...")
                    sourceControlService.getDiff(repositoryName: repository.name, pullRequestId: pullRequest.scmId, req: req).whenSuccess { diff in
                        comments = self.getCommentMetaData(violations: violations, diff: diff, onlyAddedLines: true)
                        
                        guard let generalComments = comments?.0 else {
                            logger.warning("No General Comments were generated!")
                            return
                        }
                        guard let inlineComments = comments?.1 else {
                            logger.warning("No Inline Comments were generated!")
                            return
                        }
                        
                        logger.info("General Comments: \(generalComments.count)")
                        logger.info("Inline Comments: \(inlineComments.count)")
                        
                        logger.info("Posting Inline Comments...")
                        for inlineComment in inlineComments {
                            let comment = Comment(id: nil,
                                                  line: inlineComment.0.location.line!,
                                                  lineType: inlineComment.1.type,
                                                  ruleDescription: inlineComment.0.ruleName,
                                                  content: inlineComment.0.reason,
                                                  path: String(inlineComment.0.location.relativeFile?.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)[1] ?? ""),
                                                  type: CommentType(rawValue: inlineComment.0.severity.rawValue))
                            
                            sourceControlService.postComment(repositoryName: repository.name, pullRequest: pullRequest, comment: comment, diff: diff, req: req)
                        }
                        
                        var comments: [Comment] = []
                        
                        logger.info("Aggregating General Comments...")
                        for generalComment in generalComments {
                            comments.append(Comment(id: nil,
                                                    line: nil,
                                                    lineType: "",
                                                    ruleDescription: generalComment.ruleDescription,
                                                    content: generalComment.reason,
                                                    path: "",
                                                    type: CommentType(rawValue: generalComment.severity.rawValue)))
                        }
                        
                        if !comments.isEmpty {
                            logger.info("Posting General Comments...")
                            sourceControlService.postGeneralComment(repositoryName: repository.name, pullRequest: pullRequest, comments: comments, req: req)
                        }
                        
                        if generalComments.count == 0 && inlineComments.count == 0 {
                            logger.info("Approving Pull Request...")
                            sourceControlService.approvePullRequest(repositoryName: repository.name, pullRequestId: pullRequest.scmId, req: req)
                        } else {
                            logger.info("Pull Request Needs Work...")
                            sourceControlService.markNeedsRework(repositoryName: repository.name, pullRequestId: pullRequest.scmId, req: req).whenSuccess { _ in
                                logger.info("Generating Tasks...")
                                let newTasks = self.generateTasks(for: violations)
                                
                                if !formerTasks.isEmpty {
                                    logger.info("Resolving former tasks...")
                                    formerTasks.map { task in
                                        
                                        guard let task = task else {
                                            logger.warning("Task could not be unwrapped!")
                                            return
                                        }
                                        
                                        guard let id = task.id else {
                                            logger.warning("Task ID could not be unwrapped!")
                                            return
                                        }
                                        
                                        sourceControlService.resolveTask(id: id, req: req)
                                    }
                                }
                                
                                logger.info("Posting Tasks...")
                                sourceControlService.postTasks(repositoryName: repository.name, pullRequestId: pullRequest.scmId, tasks: newTasks, req: req).whenSuccess { status in
                                    logger.info("Deleting Sourcefolder...")
                                    self.deleteDirectory(pullRequest: pullRequest)
                                    
                                    logger.info("Generating Review Statistics...")
                                    let reviewStatistics = self.generateResult(for: violations)
                                    
                                    Developer.query(on: req.db).with(\.$repository).all().map { developers in
                                        let developerFiltered = developers.filter { $0.$repository.id == repository.id }
                                        guard let developerID = developerFiltered.first?.id else {
                                            logger.warning("Developer not found!")
                                            return
                                        }
                                        
                                        logger.info("Saving Review Statistics...")
                                        ReviewStatistics(violations: reviewStatistics,
                                                         developerID: developerID).save(on: req.db)
                                        
                                    }.whenSuccess {
                                        ReviewJobData.query(on: req.db).with(\.$pullRequest).all().map { jobs in
                                            let jobFiltered = jobs.filter { $0.$pullRequest.id == pullRequest.id }
                                            guard let job = jobFiltered.first else {
                                                logger.warning("Review Job not found!")
                                                return
                                            }
                                            
                                            logger.info("Setting Job Status...")
                                            job.status = .done
                                            job.update(on: req.db).map {
                                                logger.info("Reviewer Job ended successful!")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

extension Review {
    func deleteDirectory(pullRequest: PullRequest) {
        let dirs = DirectoryConfiguration.self
        let path = dirs.detect().workingDirectory
        let fileManager = FileManager()
        
        let shortHash = pullRequest.latestCommit.prefix(8)
        
        do {
            logger.info("Deleting directory: sources_\(shortHash)")
            try fileManager.removeItem(atPath: path + "sources_" + shortHash)
        } catch {
            logger.info("\(error.localizedDescription)")
        }
    }
    
    func directoryExists(pullRequest: PullRequest) -> Bool {
        let dirs = DirectoryConfiguration.self
        let path = dirs.detect().workingDirectory
        let fileManager = FileManager()
        
        let shortHash = pullRequest.latestCommit.prefix(8)
        
        let directoryExists = fileManager.fileExists(atPath: path + "sources_" + shortHash)
        logger.info("Directory exists: \(directoryExists.description)")
        
        return directoryExists
    }
    
    func createDirectory(pullRequest: PullRequest) {
        let dirs = DirectoryConfiguration.self
        let path = dirs.detect().workingDirectory
        let fileManager = FileManager()
        
        let shortHash = pullRequest.latestCommit.prefix(8)
        
        do {
            logger.info("Creating directory: sources_\(shortHash)")
            try fileManager.createDirectory(atPath: path + "sources_" + shortHash, withIntermediateDirectories: false, attributes: nil)
        } catch {
            logger.info("\(error.localizedDescription)")
        }
    }
    
    func unzipSources(fileName: String, fileExtension: String, pullRequest: PullRequest) {
        let dirs = DirectoryConfiguration.self
        let path = dirs.detect().workingDirectory
        let fileManager = FileManager()
        
        let shortHash = pullRequest.latestCommit.prefix(8)
        
        do {
            logger.info("Unzip sources...")
            try fileManager.unzipItem(at: URL(fileURLWithPath: path + "sources_" + shortHash + "/" + fileName + fileExtension), to: URL(fileURLWithPath: path + "sources_" + shortHash))
        } catch {
            logger.info("\(error.localizedDescription)")
        }
    }
    
    func generateTasks(for violations: [StyleViolation]) -> [Task] {
        let ruleDescriptionNames = violations.map { violation in
            violation.ruleName
        }
        
        let repeatedElements = repeatElement(1, count: ruleDescriptionNames.count)
        
        let tasksDictionary = Dictionary(zip(ruleDescriptionNames, repeatedElements), uniquingKeysWith: +)
        
        return tasksDictionary.map { task in
            return Task(description: task.key, occurence: task.value)
        }
    }
    
    func generateResult(for violations: [StyleViolation]) -> [String:Int] {
        let ruleDescriptionNames = violations.map { violation in
            violation.ruleName
        }
        
        let repeatedElements = repeatElement(1, count: ruleDescriptionNames.count)
        
        let resultDictionary = Dictionary(zip(ruleDescriptionNames, repeatedElements), uniquingKeysWith: +)
        
        return resultDictionary
    }
    
    func getCommentMetaData(violations: [StyleViolation], diff: Diff, onlyAddedLines: Bool = false) -> ([StyleViolation], [(StyleViolation, Segment)]) {
        let diffFiles = diff.diffs

        var generalViolations: [StyleViolation] = []
        var inlineFindings: [(StyleViolation, Segment)] = []

        violations.forEach { violation in
            guard let line = violation.location.line else { return }

            let matchingFile = diffFiles.first { diffFile in
                guard let substring = diffFile.destination?.toString else { return false }
                let string = violation.location.file
                return string?.contains(substring) ?? false
            }

            guard matchingFile != nil else { return generalViolations.append(violation) }

            let matchingHunk = matchingFile?.hunks?.first { hunk in
                let firstLine = hunk.destinationLine
                let lastLine = hunk.destinationLine! + hunk.destinationSpan! - 1
                return line >= firstLine! && line <= lastLine
            }

            guard matchingHunk != nil else { return generalViolations.append(violation) }

            let matchingSegment = matchingHunk?.segments!.filter { segment in
                !onlyAddedLines || segment.type == "ADDED"
            }.first { seg in
                seg.lines!.contains { currentLine in
                    currentLine.destination == line
                }
            }

            guard matchingSegment != nil else { return generalViolations.append(violation) }

            inlineFindings.append((violation, matchingSegment!))

        }
        return (generalViolations, inlineFindings)
    }
}
