# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# Ruby 3.4 no longer ships base64 as a default gem.
gem "base64"

# Needed by the allocation-sensitive integration tests.
gem "lru_redux"

install_if -> { RUBY_PLATFORM !~ /mingw|mswin|java/ && RUBY_ENGINE == "ruby" } do
  gem "stackprof"
end
