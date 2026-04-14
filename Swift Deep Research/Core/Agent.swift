import Foundation

// MARK: - Error Definitions

/// Errors that can occur during the research process
enum ResearchError: LocalizedError {
    case noSearchResults
    case tokenBudgetExceeded(currentUsage: Int, budget: Int)
    case invalidLLMResponse(String)
    case cancelled
    case providerError(String)
    
    var errorDescription: String? {
        switch self {
        case .noSearchResults:
            return "No search results found. Please try a different or more specific query."
        case .tokenBudgetExceeded(let current, let budget):
            return "Token budget exceeded: \(current) > \(budget)"
        case .invalidLLMResponse(let message):
            return "Could not parse LLM response: \(message)"
        case .cancelled:
            return "Research was cancelled."
        case .providerError(let message):
            return "LLM provider error: \(message)"
        }
    }
}

// MARK: - Agent Configuration

/// Configuration for tuning agent behavior
struct AgentConfiguration {
    let stepSleep: UInt64  // nanoseconds between steps
    let maxAttempts: Int   // max bad attempts before fallback
    let tokenBudget: Int   // max approximate tokens
    let maxSearchQueries: Int  // max search queries to generate
    let maxWebpagesPerQuery: Int  // max webpages to fetch per query
    
    static let `default` = AgentConfiguration(
        stepSleep: 500_000_000,  // 0.5 seconds
        maxAttempts: 5,
        tokenBudget: 500_000,
        maxSearchQueries: 4,
        maxWebpagesPerQuery: 5
    )
    
    static let fast = AgentConfiguration(
        stepSleep: 250_000_000,
        maxAttempts: 3,
        tokenBudget: 200_000,
        maxSearchQueries: 2,
        maxWebpagesPerQuery: 3
    )
    
    static let thorough = AgentConfiguration(
        stepSleep: 1_000_000_000,
        maxAttempts: 8,
        tokenBudget: 1_000_000,
        maxSearchQueries: 6,
        maxWebpagesPerQuery: 8
    )
}

// MARK: - Research Progress

/// A single step in the research process for UI display
struct ResearchStep: Identifiable {
    let id = UUID()
    let timestamp: Date
    let type: StepType
    let title: String
    let detail: String?
    var urls: [String]?
    var isExpanded: Bool = false
    
    enum StepType: String {
        case query = "magnifyingglass"
        case search = "globe"
        case reading = "doc.text"
        case thinking = "brain"
        case answer = "checkmark.circle"
        case error = "exclamationmark.triangle"
    }
}

/// Represents the current state of research for UI updates
struct ResearchProgress {
    var phase: ResearchPhase
    var currentQuery: String?
    var sourcesFound: Int
    var sourcesProcessed: Int
    var iterations: Int
    var statusMessage: String
    var steps: [ResearchStep] = []
    var searchQueries: [String] = []
    var urlsBeingRead: [String] = []
    var currentThinking: String?
    
    enum ResearchPhase: String {
        case starting = "Starting research..."
        case generatingQueries = "Generating search queries..."
        case searching = "Searching the web..."
        case extractingContent = "Reading webpages..."
        case analyzing = "Analyzing information..."
        case synthesizing = "Synthesizing answer..."
        case reflecting = "Reflecting on findings..."
        case complete = "Research complete"
    }
    
    static let initial = ResearchProgress(
        phase: .starting,
        currentQuery: nil,
        sourcesFound: 0,
        sourcesProcessed: 0,
        iterations: 0,
        statusMessage: "Starting research...",
        steps: [],
        searchQueries: [],
        urlsBeingRead: [],
        currentThinking: nil
    )
    
    mutating func addStep(_ type: ResearchStep.StepType, title: String, detail: String? = nil, urls: [String]? = nil) {
        steps.append(ResearchStep(timestamp: Date(), type: type, title: title, detail: detail, urls: urls))
    }
}

// MARK: - Agent Diary

/// Logs internal agent events for debugging and transparency
struct AgentDiary {
    private(set) var entries: [DiaryEntry] = []
    
    struct DiaryEntry {
        let timestamp: Date
        let message: String
        let type: EntryType
        
        enum EntryType {
            case info, search, extract, llm, error, decision
        }
    }
    
    mutating func add(_ message: String, type: DiaryEntry.EntryType = .info) {
        entries.append(DiaryEntry(timestamp: Date(), message: message, type: type))
    }
    
    func log() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return entries.map { entry in
            "[\(formatter.string(from: entry.timestamp))] \(entry.message)"
        }.joined(separator: "\n")
    }
    
    func recentEntries(_ count: Int = 10) -> [DiaryEntry] {
        Array(entries.suffix(count))
    }
}

// MARK: - Research Agent

/// The Agent orchestrates web search, content extraction, LLM reasoning, and iterative research.
@MainActor
class Agent: ObservableObject {
    
    // MARK: - Dependencies
    let searchService: SearchServiceProtocol
    let webReaderService: ContentExtractor 
    let llmProvider: LLMProviderProtocol
    let systemPrompt: String
    
    // MARK: - Published State
    @Published var progress: ResearchProgress = .initial
    @Published var isRunning: Bool = false
    
    // MARK: - Internal State
    private let config: AgentConfiguration
    private var diary = AgentDiary()
    private var gaps: [String] = []
    private var visitedURLs: Set<URL> = []
    private var collectedSources: [SourceCitation] = []
    private var tokenUsage = 0
    private var isCancelled = false
    
    // Callback for streaming updates
    var onStreamingUpdate: ((String) -> Void)?
    var onProgressUpdate: ((ResearchProgress) -> Void)?
    
    init(searchService: SearchServiceProtocol,
         webReaderService: ContentExtractor,
         llmProvider: LLMProviderProtocol,
         systemPrompt: String = "",
         config: AgentConfiguration = .default
    ) {
        self.searchService = searchService
        self.webReaderService = webReaderService
        self.llmProvider = llmProvider
        self.systemPrompt = systemPrompt
        self.config = config
    }
    
    /// Cancel ongoing research
    func cancel() {
        isCancelled = true
        isRunning = false
    }
    
    /// Get collected sources
    var sources: [SourceCitation] {
        collectedSources
    }
    
    // MARK: - Main Research Method
    
    /// Performs deep research on a question and returns a comprehensive answer
    func getResponse(for question: String) async throws -> String {
        // Reset state
        isRunning = true
        isCancelled = false
        gaps = [question]
        diary = AgentDiary()
        visitedURLs = []
        collectedSources = []
        tokenUsage = 0
        
        defer { isRunning = false }
        
        updateProgress(.starting, message: "Starting research on: \(question)")
        progress.addStep(.query, title: "Research question", detail: question)
        diary.add("Starting research for: \(question)", type: .info)
        
        var badAttempts = 0
        var candidateAnswers: [String] = []
        
        // Step 1: Generate search queries
        updateProgress(.generatingQueries, message: "Generating search queries...")
        let initialQueries = try await generateSearchQueries(for: question)
        if !initialQueries.isEmpty {
            gaps = initialQueries + [question]
            progress.searchQueries = initialQueries
            progress.addStep(.query, title: "Generated \(initialQueries.count) search queries", detail: initialQueries.joined(separator: "\n• "))
            diary.add("Generated \(initialQueries.count) search queries", type: .search)
        }
        
        // Main research loop
        while !isCancelled {
            try await Task.sleep(nanoseconds: config.stepSleep)
            if Task.isCancelled || isCancelled { throw ResearchError.cancelled }
            
            let currentQuery = gaps.isEmpty ? question : gaps.removeFirst()
            progress.currentQuery = currentQuery
            progress.iterations += 1
            
            // Step 2: Search
            updateProgress(.searching, message: "Searching: \(currentQuery)")
            progress.addStep(.search, title: "Searching", detail: currentQuery)
            diary.add("Searching for: \(currentQuery)", type: .search)
            
            let searchResults = try await fetchSearchResults(for: currentQuery)
            if searchResults.isEmpty {
                progress.addStep(.error, title: "No results found", detail: currentQuery)
                diary.add("No results for: \(currentQuery)", type: .error)
                if gaps.isEmpty {
                    throw ResearchError.noSearchResults
                }
                continue
            }
            
            // Filter visited URLs
            let newResults = searchResults.filter { !visitedURLs.contains($0.url) }
                .prefix(config.maxWebpagesPerQuery)
            
            if newResults.isEmpty {
                diary.add("All URLs already visited", type: .info)
                continue
            }
            
            newResults.forEach { visitedURLs.insert($0.url) }
            progress.sourcesFound = visitedURLs.count
            
            // Step 3: Extract content
            let urlStrings = newResults.map { $0.url.absoluteString }
            progress.urlsBeingRead = urlStrings
            updateProgress(.extractingContent, message: "Reading \(newResults.count) sources...")
            progress.addStep(.reading, title: "Reading \(newResults.count) sources", detail: newResults.map { "• \($0.title)" }.joined(separator: "\n"), urls: urlStrings)
            diary.add("Extracting content from \(newResults.count) pages", type: .extract)
            
            let contents = await fetchWebpagesContent(from: Array(newResults))
            progress.sourcesProcessed += contents.count
            
            // Add to sources
            for result in newResults {
                collectedSources.append(SourceCitation(
                    title: result.title,
                    url: result.url.absoluteString,
                    snippet: nil
                ))
            }
            
            let aggregatedContent = contents.joined(separator: "\n\n---\n\n")
            
            // Step 4: Analyze with LLM
            updateProgress(.analyzing, message: "Analyzing information...")
            progress.addStep(.thinking, title: "Analyzing content", detail: "Processing \(contents.count) sources for: \(currentQuery)")
            progress.urlsBeingRead = []
            
            let prompt = buildAnalysisPrompt(
                question: question,
                currentQuery: currentQuery,
                content: aggregatedContent,
                previousFindings: candidateAnswers.last
            )
            
            tokenUsage += prompt.count
            if tokenUsage > config.tokenBudget {
                diary.add("Token budget exceeded", type: .error)
                break
            }
            
            diary.add("Invoking LLM for analysis", type: .llm)
            
            let rawResponse = try await llmProvider.processText(
                systemPrompt: buildSystemPrompt(),
                userPrompt: prompt,
                streaming: true
            )
            
            tokenUsage += rawResponse.count
            
            // Parse response
            let parseResult = LLMResponseParser.parse(from: rawResponse)
            
            switch parseResult {
            case .failure:
                // If parsing fails, treat raw response as answer
                diary.add("Using raw response as answer", type: .decision)
                candidateAnswers.append(rawResponse)
                
            case .success(let response):
                diary.add("Action: \(response.action)", type: .decision)
                
                // Capture thinking/reasoning if available
                if !response.thoughts.isEmpty {
                    progress.currentThinking = response.thoughts
                    progress.addStep(.thinking, title: "Reasoning", detail: response.thoughts)
                }
                
                switch response.action.lowercased() {
                case "answer":
                    if let answer = response.answer, !answer.isEmpty {
                        if isDefinitive(answer: answer) {
                            candidateAnswers.append(answer)
                            progress.addStep(.answer, title: "Found answer", detail: String(answer.prefix(200)) + (answer.count > 200 ? "..." : ""))
                            diary.add("Found definitive answer", type: .decision)
                        } else {
                            badAttempts += 1
                        }
                    } else {
                        badAttempts += 1
                    }
                    
                case "reflect":
                    if let subQuestions = response.questionsToAnswer, !subQuestions.isEmpty {
                        gaps.append(contentsOf: subQuestions.prefix(3))
                        progress.addStep(.thinking, title: "Identified \(subQuestions.count) follow-up questions", detail: subQuestions.joined(separator: "\n• "))
                        diary.add("Added \(subQuestions.count) sub-questions", type: .decision)
                    }
                    badAttempts += 1
                    
                case "search":
                    if let query = response.searchQuery, !query.isEmpty {
                        gaps.insert(query, at: 0)
                        progress.searchQueries.append(query)
                        progress.addStep(.search, title: "Need more information", detail: "New search: \(query)")
                        diary.add("New search query: \(query)", type: .search)
                    }
                    badAttempts += 1
                    
                default:
                    badAttempts += 1
                }
            }
            
            // Check termination conditions
            if gaps.isEmpty || badAttempts >= config.maxAttempts {
                break
            }
        }
        
        // Step 5: Synthesize final answer
        updateProgress(.synthesizing, message: "Synthesizing final answer...")
        progress.addStep(.thinking, title: "Synthesizing final answer", detail: "Combining findings from \(collectedSources.count) sources")
        
        let finalAnswer: String
        if let best = candidateAnswers.last, !best.isEmpty {
            finalAnswer = best
        } else {
            finalAnswer = try await synthesizeFinalAnswer(for: question)
        }
        
        // Update memory with any insights
        parseMemoryUpdates(from: finalAnswer)
        
        updateProgress(.complete, message: "Research complete")
        
        return finalAnswer
    }
    
    // MARK: - Progress Updates
    
    private func updateProgress(_ phase: ResearchProgress.ResearchPhase, message: String) {
        progress.phase = phase
        progress.statusMessage = message
        onProgressUpdate?(progress)
    }
    
    // MARK: - Search Query Generation
    
    private func generateSearchQueries(for question: String) async throws -> [String] {
        let prompt = """
        Generate \(config.maxSearchQueries) diverse search queries to research this question:
        "\(question)"
        
        Create queries that:
        1. Cover different aspects of the topic
        2. Use varied terminology and phrasing
        3. Include both broad and specific searches
        4. Target authoritative sources when relevant
        
        Return ONLY a JSON object:
        {"queries": ["query1", "query2", "query3", "query4"]}
        """
        
        do {
            let response = try await llmProvider.processText(
                systemPrompt: "You generate search queries. Return only valid JSON.",
                userPrompt: prompt,
                streaming: false
            )
            
            struct QueryResponse: Codable { let queries: [String] }
            
            // Try to extract JSON from response
            let jsonString = extractJSON(from: response)
            if let data = jsonString.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(QueryResponse.self, from: data) {
                return Array(parsed.queries.filter { !$0.isEmpty }.prefix(config.maxSearchQueries))
            }
        } catch {
            diary.add("Query generation failed: \(error.localizedDescription)", type: .error)
        }
        
        return [question]
    }
    
    // MARK: - Search
    
    private func fetchSearchResults(for query: String) async throws -> [SearchResult] {
        do {
            let results = try await searchService.search(query: query)
            return results
        } catch {
            diary.add("Search failed: \(error.localizedDescription)", type: .error)
            return []
        }
    }
    
    // MARK: - Content Extraction
    
    private func fetchWebpagesContent(from results: [SearchResult]) async -> [String] {
        var contents: [String] = []
        
        await withTaskGroup(of: String?.self) { group in
            for result in results {
                group.addTask {
                    let finalURL = ContentExtractionFactory.resolveRedirect(for: result.url)
                    let extractor = ContentExtractionFactory.createExtractor(for: finalURL)
                    
                    do {
                        let content = try await extractor.extractContent(from: finalURL)
                        // Truncate very long content
                        let maxLength = 15000
                        if content.count > maxLength {
                            return String(content.prefix(maxLength)) + "\n[Content truncated...]"
                        }
                        return content
                    } catch {
                        return nil
                    }
                }
            }
            
            for await content in group {
                if let content = content, !content.isEmpty {
                    contents.append(content)
                }
            }
        }
        
        return contents
    }
    
    // MARK: - System Prompt
    
    private func buildSystemPrompt() -> String {
        var prompt = systemPrompt.isEmpty ? defaultSystemPrompt : systemPrompt
        
        // Add memory context if available
        if AppSettings.shared.enableMemory {
            prompt += MemoryManager.shared.formatForPrompt()
        }
        
        return prompt
    }
    
    private var defaultSystemPrompt: String {
        """
        You are an expert research assistant. Your role is to analyze information from web sources and provide accurate, well-reasoned answers.
        
        Guidelines:
        - Use ONLY information from the provided sources
        - Cite specific evidence with quotes when possible
        - Acknowledge uncertainty when information is incomplete
        - Think step-by-step before answering
        - Be concise but comprehensive
        
        If you learn important facts about the user's preferences or context, save them using:
        [MEMORY:category]content[/MEMORY]
        Categories: preference, project, insight, correction, instruction, general
        """
    }
    
    // MARK: - Analysis Prompt
    
    private func buildAnalysisPrompt(question: String,
                                      currentQuery: String,
                                      content: String,
                                      previousFindings: String?) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let currentDate = dateFormatter.string(from: Date())
        
        var prompt = """
        # Research Task
        
        **Date:** \(currentDate)
        **Original Question:** \(question)
        **Current Focus:** \(currentQuery)
        
        ## Source Content
        
        \(content)
        
        """
        
        if let previous = previousFindings, !previous.isEmpty {
            prompt += """
            
            ## Previous Findings
            
            \(previous)
            
            """
        }
        
        prompt += """
        
        ## Instructions
        
        Analyze the source content to answer the question. You must respond with valid JSON:
        
        ```json
        {
          "action": "answer" | "search" | "reflect",
          "thoughts": "Your step-by-step reasoning process",
          "answer": "Your comprehensive answer (if action is 'answer')",
          "searchQuery": "A new search query (if action is 'search')",
          "questionsToAnswer": ["Sub-questions to explore (if action is 'reflect')"],
          "confidence": "high" | "medium" | "low",
          "references": [{"exactQuote": "quote", "url": "source"}]
        }
        ```
        
        Choose:
        - "answer" if you have enough information for a complete response
        - "search" if you need more specific information
        - "reflect" if the question needs to be broken into sub-questions
        """
        
        return prompt
    }
    
    // MARK: - Answer Validation
    
    private func isDefinitive(answer: String) -> Bool {
        let lower = answer.lowercased()
        
        // Check for uncertainty markers
        let uncertaintyPhrases = [
            "i don't know",
            "i'm not sure",
            "unsure",
            "not available",
            "cannot determine",
            "no information",
            "unclear"
        ]
        
        for phrase in uncertaintyPhrases {
            if lower.contains(phrase) {
                return false
            }
        }
        
        // Answer should be substantive
        return answer.count > 50
    }
    
    // MARK: - Final Synthesis
    
    private func synthesizeFinalAnswer(for question: String) async throws -> String {
        let diaryLog = diary.log()
        let sourcesText = collectedSources.map { "- \($0.title): \($0.url)" }.joined(separator: "\n")
        
        let prompt = """
        # Final Synthesis Required
        
        After extensive research, synthesize a comprehensive answer to:
        **\(question)**
        
        ## Research Log
        \(diaryLog)
        
        ## Sources Consulted
        \(sourcesText)
        
        ## Instructions
        Provide your best possible answer based on all research conducted. Be comprehensive, cite evidence, and acknowledge any limitations in the available information.
        
        Write your answer in clear, well-structured prose. Do not use JSON format for this response.
        """
        
        let answer = try await llmProvider.processText(
            systemPrompt: "You are synthesizing research findings into a final, comprehensive answer.",
            userPrompt: prompt,
            streaming: true
        )
        
        return answer
    }
    
    // MARK: - Memory Updates
    
    private func parseMemoryUpdates(from response: String) {
        Task { @MainActor in
            MemoryManager.shared.parseAndUpdateFromResponse(response)
        }
    }
    
    // MARK: - Helpers
    
    private func extractJSON(from text: String) -> String {
        // Try to find JSON object in the text
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove markdown code blocks
        cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
        cleaned = cleaned.replacingOccurrences(of: "```", with: "")
        
        // Find JSON boundaries
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            return String(cleaned[start...end])
        }
        
        return cleaned
    }
}
