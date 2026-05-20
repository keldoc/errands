# frozen_string_literal: true

$LOAD_PATH.unshift File.join(File.dirname(__FILE__), 'lib')

require 'errands/version'

Gem::Specification.new do |spec|
  spec.required_ruby_version  = '>= 3.4.9'
  spec.name                   = 'errands'
  spec.version                = Errands::VERSION
  spec.authors                = ['lacravate']
  spec.email                  = ['lacravate@lacravate.fr']
  spec.homepage               = 'https://github.com/lacravate/errands'
  spec.summary                = 'Turn a model into a threaded service'
  spec.description            =
    'A code frame to have an orderly use of thread and separate runtime and actual job of a Ruby class'

  spec.files                  = `git ls-files app lib`.split("\n")
  spec.platform               = Gem::Platform::RUBY
  spec.require_paths          = ['lib']

  spec.add_development_dependency 'pry', '~> 0.16.0'
  spec.add_development_dependency 'rspec', '~> 3.5'
  spec.add_development_dependency 'simplecov', '~> 0.22.0'
end
