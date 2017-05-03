# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'celluloid/eventsource/version'

Gem::Specification.new do |spec|
  spec.name          = "ld-celluloid-eventsource"
  spec.version       = Celluloid::EventSource::VERSION
  spec.authors       = ["LaunchDarkly"]
  spec.email         = ["dev@launchdarkly.com"]
  spec.description   = %q{Celluloid::IO based library to consume Server-Sent Events. This library was forked from https://github.com/Tonkpils/celluloid-eventsource}
  spec.summary       = %q{ld-celluloid-eventsource is a gem to consume SSE streaming API.}
  spec.homepage      = "https://github.com/launchdarkly/celluloid-eventsource"
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_dependency 'celluloid-io', '~> 0.17.3'
  spec.add_dependency 'celluloid', '~> 0.18.0.pre'
  spec.add_dependency 'http_parser.rb', '~> 0.6.0'

  spec.add_development_dependency 'atomic', '~> 1.1'
  spec.add_development_dependency "rspec", '~> 3.0'
  spec.add_development_dependency "bundler", "~> 1.7"
  spec.add_development_dependency "rake", '~> 10.1'
  spec.add_development_dependency "pry", '~> 0.9'
end
