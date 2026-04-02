# frozen_string_literal: true

# ── Capture pristine stdlib methods BEFORE loading target code ──
# This prevents agents from monkey-patching timing/allocation/GC functions
# in lib/ to fake benchmark results.
require "objspace"
EVAL_CLOCK = Process.method(:clock_gettime)
EVAL_COUNT_OBJECTS = ObjectSpace.method(:count_objects)
EVAL_GC_START = GC.method(:start)
EVAL_GC_COMPACT = GC.respond_to?(:compact) ? GC.method(:compact) : nil
EVAL_GC_DISABLE = GC.method(:disable)
EVAL_GC_ENABLE = GC.method(:enable)

target_root = File.expand_path(ARGV.fetch(0))
$LOAD_PATH.unshift(File.join(target_root, "lib"))
load File.join(target_root, "performance/theme_runner.rb")

RubyVM::YJIT.enable if defined?(RubyVM::YJIT)

module EvalBenchTarget
  module_function

  def salted_source(source, salt)
    return nil unless source

    "#{source}\n{% comment %}eval-cold-parse:#{salt}{% endcomment %}"
  end

  # Walk all modules/classes under the Liquid namespace.
  def each_liquid_module
    seen = {}
    queue = [Liquid]
    while (mod = queue.shift)
      next if seen[mod.object_id]
      seen[mod.object_id] = true
      yield mod
      mod.constants(false).each do |c|
        begin
          val = mod.const_get(c, false)
          queue << val if val.is_a?(Module)
        rescue
          # skip autoload or uninitialized constants
        end
      end
    end
  end

  # Snapshot all mutable Hash state under the Liquid namespace:
  # instance variables, class variables, AND constants.
  # Returns a hash of snapshots.
  def snapshot_liquid_state
    snapshots = {}
    each_liquid_module do |mod|
      mod.instance_variables.each do |ivar|
        val = mod.instance_variable_get(ivar)
        snapshots[[mod, :ivar, ivar]] = val.dup if val.is_a?(Hash) && !val.frozen?
      end
      if mod.respond_to?(:class_variables)
        mod.class_variables.each do |cv|
          val = mod.class_variable_get(cv)
          snapshots[[mod, :cvar, cv]] = val.dup if val.is_a?(Hash) && !val.frozen?
        end
      end
      # Also snapshot mutable Hash constants (e.g., VARIABLE_TOKEN_CACHE = {})
      # Agents can store caches as constants to bypass ivar/cvar clearing.
      mod.constants(false).each do |c|
        begin
          val = mod.const_get(c, false)
          next if val.is_a?(Module) # skip nested modules/classes
          snapshots[[mod, :const, c]] = val.dup if val.is_a?(Hash) && !val.frozen?
        rescue
        end
      end
    end
    snapshots
  end

  # Restore all mutable Hash state to a previous snapshot.
  # Hashes added during warmup (not in snapshot) are cleared.
  # Hashes that existed but grew during warmup are restored.
  # Covers instance variables, class variables, AND constants.
  def restore_liquid_state(snapshots)
    each_liquid_module do |mod|
      mod.instance_variables.each do |ivar|
        val = mod.instance_variable_get(ivar)
        next unless val.is_a?(Hash) && !val.frozen?
        key = [mod, :ivar, ivar]
        if snapshots.key?(key)
          val.replace(snapshots[key])
        else
          val.clear
        end
      end
      if mod.respond_to?(:class_variables)
        mod.class_variables.each do |cv|
          val = mod.class_variable_get(cv)
          next unless val.is_a?(Hash) && !val.frozen?
          key = [mod, :cvar, cv]
          if snapshots.key?(key)
            val.replace(snapshots[key])
          else
            val.clear
          end
        end
      end
      # Restore mutable Hash constants
      mod.constants(false).each do |c|
        begin
          val = mod.const_get(c, false)
          next if val.is_a?(Module)
          next unless val.is_a?(Hash) && !val.frozen?
          key = [mod, :const, c]
          if snapshots.key?(key)
            val.replace(snapshots[key])
          else
            val.clear
          end
        rescue
        end
      end
    end
  end
end

runner = ThemeRunner.new
tests = runner.instance_variable_get(:@tests)

raise "ThemeRunner test corpus did not load" unless tests.is_a?(Array) && !tests.empty?

# Snapshot all mutable class-level Hash state BEFORE warmup.
# This captures legitimate state (operator tables, tag registrations, etc.)
# and excludes any caches that warmup will populate.
pre_warmup_state = EvalBenchTarget.snapshot_liquid_state

# Warm up render paths with the real compiled templates.
20.times { runner.render }

# Warm up parser paths using salted variants so whole-document parse caches
# cannot make the parse benchmark artificially free.
20.times do |iter|
  tests.each_with_index do |test_hash, idx|
    salt = "warmup-#{iter}-#{idx}"
    Liquid::Template.new.parse(EvalBenchTarget.salted_source(test_hash[:liquid], salt))
    layout = test_hash[:layout]
    Liquid::Template.new.parse(EvalBenchTarget.salted_source(layout, salt)) if layout
  end
end

EVAL_GC_START.call
EVAL_GC_COMPACT.call if EVAL_GC_COMPACT

# Identify which mutable Hashes are caches (grew during warmup) vs config
# (operators, tag registrations — existed before warmup and didn't change).
# Must be done BEFORE restore, while pools are still warm from warmup.
clearable_pools = []
EvalBenchTarget.each_liquid_module do |mod|
  mod.instance_variables.each do |ivar|
    val = mod.instance_variable_get(ivar)
    next unless val.is_a?(Hash) && !val.frozen?
    key = [mod, :ivar, ivar]
    pre = pre_warmup_state[key]
    clearable_pools << val if pre.nil? || val.size > pre.size
  end
  if mod.respond_to?(:class_variables)
    mod.class_variables.each do |cv|
      val = mod.class_variable_get(cv)
      next unless val.is_a?(Hash) && !val.frozen?
      key = [mod, :cvar, cv]
      pre = pre_warmup_state[key]
      clearable_pools << val if pre.nil? || val.size > pre.size
    end
  end
  mod.constants(false).each do |c|
    begin
      val = mod.const_get(c, false)
      next if val.is_a?(Module)
      next unless val.is_a?(Hash) && !val.frozen?
      key = [mod, :const, c]
      pre = pre_warmup_state[key]
      clearable_pools << val if pre.nil? || val.size > pre.size
    rescue
    end
  end
end

# Now restore pre-warmup state
EvalBenchTarget.restore_liquid_state(pre_warmup_state)

parse_times = []
10.times do |iter|
  EvalBenchTarget.restore_liquid_state(pre_warmup_state)
  EVAL_GC_START.call
  EVAL_GC_DISABLE.call
  t0 = EVAL_CLOCK.call(Process::CLOCK_MONOTONIC)
  tests.each_with_index do |test_hash, idx|
    # Clear pools between templates to prevent cross-template cache hits
    i = 0
    while i < clearable_pools.size
      clearable_pools[i].clear
      i += 1
    end
    salt = "parse-#{iter}-#{idx}"
    Liquid::Template.new.parse(EvalBenchTarget.salted_source(test_hash[:liquid], salt))
    layout = test_hash[:layout]
    Liquid::Template.new.parse(EvalBenchTarget.salted_source(layout, salt)) if layout
  end
  t1 = EVAL_CLOCK.call(Process::CLOCK_MONOTONIC)
  EVAL_GC_ENABLE.call
  EVAL_GC_START.call
  parse_times << (t1 - t0) * 1_000_000
end

# Restore state before render timing
EvalBenchTarget.restore_liquid_state(pre_warmup_state)

render_times = []
10.times do
  EVAL_GC_DISABLE.call
  t0 = EVAL_CLOCK.call(Process::CLOCK_MONOTONIC)
  runner.render
  t1 = EVAL_CLOCK.call(Process::CLOCK_MONOTONIC)
  EVAL_GC_ENABLE.call
  EVAL_GC_START.call
  render_times << (t1 - t0) * 1_000_000
end

# Restore state before allocation measurement
EvalBenchTarget.restore_liquid_state(pre_warmup_state)

EVAL_GC_START.call
EVAL_GC_DISABLE.call
before = EVAL_COUNT_OBJECTS.call.values_at(:TOTAL).first - EVAL_COUNT_OBJECTS.call.values_at(:FREE).first
runner.send(:each_test) do |liquid, layout, assigns, page_template, template_name|
  # Clear pools between templates to prevent cross-template allocation sharing
  i = 0
  while i < clearable_pools.size
    clearable_pools[i].clear
    i += 1
  end
  salt = "alloc-#{template_name}"
  compiled = runner.send(
    :compile_test,
    EvalBenchTarget.salted_source(liquid, salt),
    EvalBenchTarget.salted_source(layout, salt),
    assigns,
    page_template,
    template_name,
  )
  runner.send(:render_layout, compiled[:tmpl], compiled[:layout], compiled[:assigns])
end
after = EVAL_COUNT_OBJECTS.call.values_at(:TOTAL).first - EVAL_COUNT_OBJECTS.call.values_at(:FREE).first
EVAL_GC_ENABLE.call

parse_us = parse_times.min.round(0)
render_us = render_times.min.round(0)
combined_us = parse_us + render_us
allocations = after - before

puts "RESULTS"
puts "parse_us=#{parse_us}"
puts "render_us=#{render_us}"
puts "combined_us=#{combined_us}"
puts "allocations=#{allocations}"
