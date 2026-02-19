# misja_3_API/machine_verification.rb
require 'net/http'
require 'json'
require 'uri'
require 'csv'
require 'set'

module PersistentCache
  # ... (module is unchanged)
  CACHE_FILE = 'cache.csv'.freeze
  def self.load_cache(script_dir); @path = File.join(script_dir, CACHE_FILE); @cache = []; return unless File.exist?(@path); CSV.foreach(@path, headers: true) { |row| @cache << { pattern: Regexp.new(row['pattern'], Regexp::IGNORECASE), answer: row['answer'] } }; puts "Loaded #{@cache.size} entries from persistent cache."; end
  def self.get_answer(question); @cache.each { |entry| return { answer: entry[:answer], pattern: entry[:pattern].source } if question.match?(entry[:pattern]) }; nil; end
  def self.update_cache(keyword, answer); return if @cache.any? { |entry| entry[:pattern].source.casecmp?(keyword) }; CSV.open(@path, "a") { |csv| csv << [keyword, answer] }; @cache << { pattern: Regexp.new(keyword, Regexp::IGNORECASE), answer: answer }; puts "Cache updated with new entry: #{keyword} -> #{answer}"; end
  def self.delete_entry(bad_pattern); puts "Deleting incorrect entry from cache: #{bad_pattern}"; @cache.reject! { |entry| entry[:pattern].source == bad_pattern }; rows = @cache.map { |entry| [entry[:pattern].source, entry[:answer]] }; CSV.open(@path, "w") { |csv| csv << ["pattern", "answer"]; rows.each { |row| csv << row } }; end
end

# BAML client now uses Ollama for both keyword and answer extraction.
module BAML
  class Client
    OLLAMA_URI = URI('http://localhost:11434/api/generate')

    def extract_keywords(question)
      keywords = []
      begin
        prompt = "From the sentence, extract a single, simple, lowercase noun to use as a search keyword. Sentence: \"#{question}\" Keyword:"
        payload = { model: "gemma3:latest", prompt: prompt, stream: false }
        response_json = post_to_ollama(payload)
        keyword = response_json['response'].strip.gsub('"', '').split.first
        keywords << keyword unless keyword.empty?
      rescue => e; puts "Ollama keyword Error: #{e.message}"; end
      keywords << fallback_heuristic(question)
      keywords.uniq
    end
    
    def extract_answer(question, hint)
        puts "Using Ollama (gemma3:latest) to extract answer..."
        prompt = <<~PROMPT
        You are an expert at finding specific information. From the context sentence, extract the single word that answers the question.
        The answer is usually a proper noun (like 'Persona' or 'Synthetix') or a 4-digit year.
        
        Question: "#{question}"
        Context: "#{hint}"
        
        Single-word Answer:
        PROMPT
        
        payload = { model: "gemma3:latest", prompt: prompt, stream: false }
        
        begin
          response_json = post_to_ollama(payload)
          answer = response_json['response'].strip.gsub('"', '').split.first
          puts "Ollama answer: '#{answer}'"
          return answer
        rescue => e
          puts "Ollama answer Error: #{e.message}. Could not determine answer."
          return nil
        end
    end
    
    def post_to_ollama(payload); http = Net::HTTP.new(OLLAMA_URI.host, OLLAMA_URI.port); request = Net::HTTP::Post.new(OLLAMA_URI.path, 'Content-Type' => 'application/json'); request.body = payload.to_json; JSON.parse(http.request(request).body); end
    def fallback_heuristic(question); excluded_words = %w[jaka w którym kto jak nazywa się do z i o na]; words = question.gsub('?', '').split; (words.reverse.find { |w| !excluded_words.include?(w.downcase) } || words.last).downcase.gsub(/[?.,]/, ''); end
  end
end

class MachineVerification
  # ... (The rest of the class is identical to the previous version)
  MAX_HINT_FETCHES = 3
  def initialize(config_path: 'config.json'); @script_dir = File.dirname(__FILE__); full_config_path = File.join(@script_dir, config_path); @config = JSON.parse(File.read(full_config_path)); @base_url = @config['base_url']; @verification_endpoint = @config['verification_endpoint']; @knowledge_endpoint = @config['knowledge_endpoint']; @baml_client = BAML::Client.new; PersistentCache.load_cache(@script_dir); end
  def run; puts "Starting verification with full LLM intelligence..."; response = get(@verification_endpoint); return puts "Failed to get questions: #{response}" if response.nil? || response.key?('error'); questions, token = response['pytania'], response['token']; puts "Got questions and token."; answers_with_provenance = get_answers(questions); if answers_with_provenance.any? { |a| a.nil? || a[:answer].nil? }; return puts "Failed to get all answers. Aborting."; end; answers = answers_with_provenance.map { |a| a[:answer] }; puts "Got answers: #{answers.join(', ')}"; final_response = submit_answers(answers, token); process_feedback(final_response, answers_with_provenance) if final_response && final_response['is_correct']; end
  private
  def get_answers(questions); answers = Array.new(questions.size); questions_to_fetch = []; questions.each_with_index { |q, i| (answers[i] = PersistentCache.get_answer(q)) ? puts("Cache HIT for: '#{q}'") : questions_to_fetch << { q: q, i: i } }; if !questions_to_fetch.empty?; puts "Cache MISS for #{questions_to_fetch.size} question(s). Using LLM..."; threads = questions_to_fetch.take(MAX_HINT_FETCHES).map do |item|; Thread.new do; q, i = item[:q], item[:i]; keywords = @baml_client.extract_keywords(q); answers[i] = { answer: nil, source: :llm_failed }; keywords.each do |keyword|; next if keyword.nil? || keyword.empty?; puts "Attempting keyword: '#{keyword}'..."; hint_response = get(@knowledge_endpoint + URI.encode_www_form_component(keyword)); if hint_response && hint_response['hint']; puts "Keyword '#{keyword}' was successful."; answer = @baml_client.extract_answer(q, hint_response['hint']); answers[i] = { answer: answer, source: :llm, keyword: keyword }; break; else; puts "Keyword '#{keyword}' failed. Trying next..."; end; end; end; end; threads.each(&:join); end; answers; end
  def submit_answers(answers, token); payload = { odpowiedzi: answers, token: token }; puts "Submitting answers..."; response = post(@verification_endpoint, payload); puts "Final Response:", response || "No response"; response; end
  def process_feedback(response, answers_with_provenance); correctness_array = response['is_correct']; correctness_array.each_with_index do |is_correct, i|; provenance = answers_with_provenance[i]; next if provenance.nil?; if !is_correct && provenance[:source] == :cache; PersistentCache.delete_entry(provenance[:pattern]); elsif is_correct && provenance[:source] == :llm; PersistentCache.update_cache(provenance[:keyword], provenance[:answer]) if provenance[:answer]; end; end; end
  def get(path); uri = URI.join(@base_url, path); begin; http = Net::HTTP.new(uri.host, uri.port); http.use_ssl = true; response = http.request(Net::HTTP::Get.new(uri.request_uri)); return { "error" => "API Error", "body" => response.body } if response.content_type != 'application/json'; JSON.parse(response.body); rescue => e; puts "Error in GET to #{uri}: #{e.message}"; nil; end; end
  def post(path, payload); uri = URI.join(@base_url, path); begin; http = Net::HTTP.new(uri.host, uri.port); http.use_ssl = true; request = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json'); request.body = payload.to_json; response = http.request(request); return { "error" => "API Error", "body" => response.body } if response.content_type != 'application/json'; JSON.parse(response.body); rescue => e; puts "Error in POST to #{uri}: #{e.message}"; nil; end; end
end

if __FILE__ == $0
  verifier = MachineVerification.new
  verifier.run
end
