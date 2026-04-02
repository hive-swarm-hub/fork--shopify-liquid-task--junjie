# frozen_string_literal: true

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
$LOAD_PATH.unshift(File.join(root, "test"))

Dir[File.join(root, "test/{integration,unit}/**/*_test.rb")].sort.each do |file|
  load file
end
