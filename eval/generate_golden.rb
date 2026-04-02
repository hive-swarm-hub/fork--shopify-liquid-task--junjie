# frozen_string_literal: true

# Generates a golden render output file from the reference-pr implementation.
# This is used by the eval to verify that candidate code produces correct output.

target_root = File.expand_path(ARGV.fetch(0, "reference-pr"), File.expand_path("..", __dir__))
$LOAD_PATH.unshift(File.join(target_root, "lib"))
load File.join(target_root, "performance/theme_runner.rb")

require "digest"

runner = ThemeRunner.new

outputs = []
runner.instance_variable_get(:@compiled_tests).each_with_index do |test, idx|
  tmpl    = test[:tmpl]
  assigns = test[:assigns]
  layout  = test[:layout]

  if layout
    content = tmpl.render!(assigns.dup)
    assigns_copy = assigns.dup
    assigns_copy['content_for_layout'] = content
    result = layout.render!(assigns_copy)
  else
    result = tmpl.render!(assigns.dup)
  end

  outputs << result
end

# Output a SHA256 digest of all concatenated render outputs.
# This is deterministic for a given codebase + templates + data.
combined = outputs.join("\x00")
puts Digest::SHA256.hexdigest(combined)
