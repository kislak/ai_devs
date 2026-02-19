require 'net/http'
require 'json'
require 'uri'

BASE_URL = 'https://story.aidevs.pl'

# 1. Fetch questions and token
data = JSON.parse(Net::HTTP.get(URI("#{BASE_URL}/api-weryfikacja")))
token = data['token']
questions = data['pytania'] || data['questions']

puts "Questions: #{questions.inspect}"

# 2. Sequential solving (No LLM, whole question)
answers = questions.map do |q|
  # Fetch hint from /api-wiedza using the WHOLE question
  # Ensure we encode everything, and maybe try without the trailing question mark if it fails
  encoded_q = URI.encode_www_form_component(q.delete('?'))
  uri = URI("#{BASE_URL}/api-wiedza/#{encoded_q}")
  
  sleep 1 # Small delay to be safe
  res = Net::HTTP.get(uri)
  hint = JSON.parse(res)['hint'] rescue nil
  
  # Answer extraction: take first relevant NOUN or number
  if hint
    is_year_question = q =~ /rok|kiedy/i
    skip_h = %w[To Jest Była W Z I Na O Do Ze Została Ta Ten To Wybory Prezydentem]
    candidates = hint.scan(/[A-ZŚŁŹŻĆŃÓĄĘ][a-zżźćńółęąś]+|\d+/).reject { |w| skip_h.include?(w) }
    
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
