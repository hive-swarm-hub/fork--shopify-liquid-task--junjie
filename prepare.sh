#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

find_ruby_34() {
    if command -v ruby >/dev/null 2>&1 && ruby -e 'exit(RUBY_VERSION.start_with?("3.4.") ? 0 : 1)'; then
        command -v ruby
        return 0
    fi

    if [ -x "/opt/homebrew/opt/ruby@3.4/bin/ruby" ]; then
        echo "/opt/homebrew/opt/ruby@3.4/bin/ruby"
        return 0
    fi

    if command -v brew >/dev/null 2>&1; then
        if ! brew list --versions ruby@3.4 >/dev/null 2>&1; then
            echo "Installing ruby@3.4 via Homebrew..."
            brew install ruby@3.4
        fi
        echo "$(brew --prefix ruby@3.4)/bin/ruby"
        return 0
    fi

    return 1
}

if ! RUBY_BIN="$(find_ruby_34)"; then
    echo "ERROR: Ruby 3.4 is required. Install Ruby 3.4 with YJIT support, then rerun prepare.sh." >&2
    exit 1
fi

export PATH="$(dirname "$RUBY_BIN"):$PATH"

echo "Using Ruby: $("$RUBY_BIN" -v)"

if ! "$RUBY_BIN" --yjit -e 'exit(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? 0 : 1)'; then
    echo "ERROR: This Ruby 3.4 build does not support YJIT. Use a Ruby 3.4 build with YJIT enabled." >&2
    exit 1
fi

bundle config set --local path vendor/bundle

if bundle check >/dev/null 2>&1; then
    echo "Bundle already satisfied."
else
    bundle install
fi
