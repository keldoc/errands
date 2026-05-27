# frozen_string_literal: true

require 'simplecov'

SimpleCov.start do
  add_filter do |src|
    src.filename !~ %r{lib/errands}
  end

  add_filter do |src|
    src.filename.include? '/test_helpers/'
  end

  add_filter do |src|
    src.filename.include? 'alternate_private_access'
  end
end

require 'pry'
require 'errands'
require 'errands/test_helpers/wrapper'

RSpec.configure do |config|
  config.order = 'random'
end
