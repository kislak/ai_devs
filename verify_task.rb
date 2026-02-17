require 'net/http'
require 'json'
require 'uri'

BASE_URL = 'https://story.aidevs.pl'

# 1. Fetch questions and token
data = JSON.parse(Net::HTTP.get(URI("#{BASE_URL}/api-weryfikacja")))
token = data['token']
questions = data['pytania'] || data['questions']

puts "Questions: #{questions.inspect}"

# 2. Sequential solving with improved heuristics (No LLM)
answers = questions.map do |q|
  # Keyword extraction heuristic
  # Skip common starters, look for capitalized word OR specific topic indicators
  stop_words = %w[Jak Jaka Jako Jakie Która Który Kto W O Z Za Na Ile]
  keyword = q.scan(/[A-ZŚŁŹŻĆŃÓĄĘ][a-zżźćńółęąś]+/).reject { |w| stop_words.include?(w) }.first || 
            q.scan(/partia|rok|waluta|wybory|robot|hel|ziemia|kolonia/i).first || 
            q.split.last.delete('?')
  
  # Simple normalization
  keyword = keyword.to_s.gsub(/ie$|u$|y$/ , '') # Basic suffix removal
  keyword = 'Mars'    if keyword =~ /Mars/i
  keyword = 'Księżyc' if keyword =~ /Księżyc/i
  keyword = 'roboty'  if keyword =~ /robot/i
  keyword = 'ropa'    if keyword =~ /rop/i
  
  # Fetch hint from /api-wiedza (with delay to avoid rate limit)
  sleep 2
  uri = URI("#{BASE_URL}/api-wiedza/#{URI.encode_www_form_component(keyword)}")
  res = Net::HTTP.get(uri)
  hint = JSON.parse(res)['hint'] rescue nil
  
  # Answer extraction: take first relevant NOUN or number, skip common words
  if hint
    is_year_question = q =~ /rok|kiedy/i
    skip_h = %w[To Jest Była W Z I Na O Do Ze Została Ta Ten To Wybory Prezydentem]
    candidates = hint.scan(/[A-ZŚŁŹŻĆŃÓĄĘ][a-zżźćńółęąś]+|\d+/).reject { |w| skip_h.include?(w) }
    
    # Prioritize based on question type
    answer = if is_year_question
               candidates.find { |c| c =~ /^\d+$/ }
             else
               candidates.find { |c| c =~ /^[A-ZŚŁŹŻĆŃÓĄĘ]/ }
             end
    answer || candidates.first || hint.split.first
  else
    "Unknown"
  end
end

puts "Answers: #{answers.inspect}"

# 3. Submit solution
uri = URI("#{BASE_URL}/api-weryfikacja")
req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
req.body = { token: token, odpowiedzi: answers }.to_json
response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }

puts "Result: #{response.body}"
