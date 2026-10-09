#!/usr/bin/env ruby
# frozen_string_literal: true

# relink-project-assets.rb
#
# Keeps the Xcode project's asset references portable and in sync with the
# preset-dictionary catalog. It rewrites every absolute (machine-specific)
# reference that Xcode's "Add Files…" dialog tends to create, so that a
# fresh clone builds after `scripts/bootstrap-assets.sh`.
#
# What it does (idempotent; running it twice changes nothing):
#   • Preset dictionaries (*.mdx): SOURCE_ROOT-relative
#       ../../../preset-dicts/output/<Name>/<Name>.mdx
#   • The catalog: ../../../preset-dicts/preset-dictionaries.json
#   • App icons: the "App Icons" group points at Resources/AppIcons and its
#     children use bare file names; references to icon files that are not in
#     that folder are removed.
#   • The local Swift package reference becomes ../../.. (the repo root).
#   • Drops the stray .gitignore and dangling .mlpackage references from the
#     "Article Embeddings" group (the model is fetched by bootstrap and must
#     not become a bundled resource).
#   • Signing: every build configuration gets Local.xcconfig as its base
#     configuration and the hard-coded DEVELOPMENT_TEAM is removed
#     (see Apps/iOS/OpenMDict-iOS/Local.xcconfig.template).
#   • --sync: adds/removes mdx references so they match the catalog, sets
#     ASSET_TAGS for on-demand dictionaries (none for bundled ones) and makes
#     KnownAssetTags the union of the existing tags and the catalog's.
#
# Usage:
#   ruby scripts/relink-project-assets.rb [--dry-run] [--sync]
#                                         [--project PATH] [--catalog PATH]
#
# Prerequisites: gem install xcodeproj

require 'json'
require 'optparse'
require 'set'
require 'xcodeproj'

ROOT_DIR = File.expand_path('..', __dir__)
options = {
  project: File.join(ROOT_DIR, 'Apps/iOS/OpenMDict-iOS/OpenMDict-iOS.xcodeproj'),
  catalog: File.join(ROOT_DIR, 'preset-dicts/preset-dictionaries.json'),
  dry_run: false,
  sync: false,
}
OptionParser.new do |o|
  o.on('--project PATH') { |v| options[:project] = v }
  o.on('--catalog PATH') { |v| options[:catalog] = v }
  o.on('--dry-run') { options[:dry_run] = true }
  o.on('--sync') { options[:sync] = true }
end.parse!

MDX_REL_DIR = '../../../preset-dicts/output'
CATALOG_REL = '../../../preset-dicts/preset-dictionaries.json'
ICONS_REL_DIR = 'Resources/AppIcons'
PACKAGE_REL = '../../..'
XCCONFIG_NAME = 'Local.xcconfig'

project_dir = File.dirname(options[:project])
icons_dir = File.join(project_dir, ICONS_REL_DIR)
changes = []
log = ->(msg) { changes << msg; puts msg }

project = Xcodeproj::Project.open(options[:project])
app_target = project.targets.find { |t| t.name == 'OpenMDict-iOS' } or abort 'target OpenMDict-iOS not found'
resources = app_target.resources_build_phase

build_files_for = lambda do |ref|
  project.objects.select { |o| o.isa == 'PBXBuildFile' && o.respond_to?(:file_ref) && o.file_ref == ref }
end
remove_ref = lambda do |ref, why|
  build_files_for.call(ref).each(&:remove_from_project)
  ref.remove_from_project
  log.call("REMOVE #{ref.display_name} (#{why})")
end

# ── Catalog ─────────────────────────────────────────────────────────────
catalog = JSON.parse(File.read(options[:catalog], encoding: 'UTF-8'))
catalog_entries = catalog.fetch('dictionaries')
catalog_by_filename = catalog_entries.to_h { |d| [d.fetch('filename'), d] }
catalog_odr_tags = catalog_entries.filter_map { |d| d['odrTag'] if d['source'] == 'odr' }.uniq

# ── 1. Preset dictionaries ──────────────────────────────────────────────
mdx_refs = project.files.select { |f| f.path.to_s.end_with?('.mdx') }
mdx_group = mdx_refs.first&.parent or abort 'no .mdx references found'

mdx_refs.each do |ref|
  filename = File.basename(ref.path)
  expected = "#{MDX_REL_DIR}/#{File.basename(filename, '.mdx')}/#{filename}"
  if options[:sync] && !catalog_by_filename.key?(filename)
    remove_ref.call(ref, 'not in catalog')
    next
  end
  if ref.source_tree != 'SOURCE_ROOT' || ref.path != expected || ref.name != filename
    ref.source_tree = 'SOURCE_ROOT'
    ref.path = expected
    ref.name = filename
    log.call("RELINK #{filename} → #{expected}")
  end
end

if options[:sync]
  existing = project.files.select { |f| f.path.to_s.end_with?('.mdx') }.map { |f| File.basename(f.path) }.to_set
  catalog_entries.each do |d|
    filename = d.fetch('filename')
    next if existing.include?(filename)
    ref = mdx_group.new_reference("#{MDX_REL_DIR}/#{File.basename(filename, '.mdx')}/#{filename}", 'SOURCE_ROOT')
    ref.name = filename
    ref.last_known_file_type = 'file'
    resources.add_file_reference(ref)
    log.call("ADD #{filename} (new in catalog)")
  end

  # ASSET_TAGS: on-demand dictionaries carry their tag, bundled ones none.
  resources.files.each do |bf|
    ref = bf.file_ref
    next unless ref && ref.path.to_s.end_with?('.mdx')
    entry = catalog_by_filename[File.basename(ref.path)] or next
    wanted = entry['source'] == 'odr' && entry['odrTag'] ? { 'ASSET_TAGS' => [entry['odrTag']] } : nil
    current = bf.settings && bf.settings['ASSET_TAGS'] ? { 'ASSET_TAGS' => bf.settings['ASSET_TAGS'] } : nil
    next if current == wanted
    bf.settings = wanted
    log.call("ASSET_TAGS #{File.basename(ref.path)} → #{wanted ? wanted['ASSET_TAGS'].first : 'none'}")
  end

  # KnownAssetTags = existing ∪ catalog tags ∪ every tag some build file uses
  # (e.g. the article-embed-model pack, which is not a dictionary).
  used_tags = project.objects.select { |o| o.isa == 'PBXBuildFile' }
                     .flat_map { |bf| Array(bf.settings && bf.settings['ASSET_TAGS']) }
  attrs = project.root_object.attributes
  known = Array(attrs['KnownAssetTags'])
  merged = (known | catalog_odr_tags | used_tags).sort
  if merged != known
    attrs['KnownAssetTags'] = merged
    log.call("KnownAssetTags: #{known.size} → #{merged.size}")
  end
end

# ── 2. Catalog JSON ─────────────────────────────────────────────────────
project.files.select { |f| File.basename(f.path.to_s) == 'preset-dictionaries.json' }.each do |ref|
  next if ref.source_tree == 'SOURCE_ROOT' && ref.path == CATALOG_REL
  ref.source_tree = 'SOURCE_ROOT'
  ref.path = CATALOG_REL
  ref.name = 'preset-dictionaries.json'
  log.call("RELINK preset-dictionaries.json → #{CATALOG_REL}")
end

# ── 3. App icons ────────────────────────────────────────────────────────
icons_group = project.main_group.recursive_children.find { |c| c.isa == 'PBXGroup' && c.display_name == 'App Icons' }
abort 'group "App Icons" not found' unless icons_group
if icons_group.source_tree != 'SOURCE_ROOT' || icons_group.path != ICONS_REL_DIR
  icons_group.source_tree = 'SOURCE_ROOT'
  icons_group.path = ICONS_REL_DIR
  icons_group.name = 'App Icons'
  log.call("GROUP App Icons → #{ICONS_REL_DIR}")
end
icons_group.files.each do |ref|
  filename = File.basename(ref.path.to_s)
  unless File.exist?(File.join(icons_dir, filename))
    remove_ref.call(ref, "not in #{ICONS_REL_DIR}")
    next
  end
  wanted_type = filename.end_with?('.icon') ? 'folder.iconcomposer.icon' : 'image.png'
  if ref.source_tree != '<group>' || ref.path != filename || !ref.name.nil? || ref.last_known_file_type != wanted_type
    ref.source_tree = '<group>'
    ref.path = filename
    ref.name = nil
    ref.last_known_file_type = wanted_type
    log.call("RELINK icon #{filename}")
  end
end

# ── 4. Local Swift package ──────────────────────────────────────────────
project.root_object.package_references.each do |pkg|
  next unless pkg.isa == 'XCLocalSwiftPackageReference'
  next if pkg.relative_path == PACKAGE_REL
  log.call("PACKAGE #{pkg.relative_path} → #{PACKAGE_REL}")
  pkg.relative_path = PACKAGE_REL
end

# ── 5. Stray references in "Article Embeddings" ─────────────────────────
project.files.select { |f| %w[.gitignore].include?(File.basename(f.path.to_s)) || f.path.to_s.end_with?('.mlpackage') }.each do |ref|
  remove_ref.call(ref, 'must not be a bundled resource')
end

# ── 6. Signing via Local.xcconfig ───────────────────────────────────────
xcconfig_ref = project.files.find { |f| File.basename(f.path.to_s) == XCCONFIG_NAME }
unless xcconfig_ref
  xcconfig_ref = project.main_group.new_reference(XCCONFIG_NAME, 'SOURCE_ROOT')
  xcconfig_ref.last_known_file_type = 'text.xcconfig'
  log.call("ADD #{XCCONFIG_NAME} reference")
end
all_configs = project.build_configurations + project.targets.flat_map(&:build_configurations)
all_configs.each do |config|
  if config.base_configuration_reference != xcconfig_ref
    config.base_configuration_reference = xcconfig_ref
    log.call("XCCONFIG #{config.name} ← #{XCCONFIG_NAME}")
  end
  if config.build_settings.key?('DEVELOPMENT_TEAM')
    config.build_settings.delete('DEVELOPMENT_TEAM')
    log.call("DROP DEVELOPMENT_TEAM (#{config.name})")
  end
end
# Project-level deployment target lines are dead (every target overrides them).
project.build_configurations.each do |config|
  if config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] == '26.2'
    config.build_settings.delete('IPHONEOS_DEPLOYMENT_TARGET')
    log.call("DROP project-level IPHONEOS_DEPLOYMENT_TARGET (#{config.name})")
  end
end

# ── Report / save ───────────────────────────────────────────────────────
absolute = project.files.count { |f| f.source_tree == '<absolute>' || f.path.to_s.start_with?('/Users/') }
mdx_count = project.files.count { |f| f.path.to_s.end_with?('.mdx') }
puts
puts "Summary: #{changes.size} change(s); #{mdx_count} mdx references; #{absolute} absolute reference(s) remaining"
abort 'ERROR: absolute references remain' if absolute.positive?

if options[:dry_run]
  puts '(dry run — project not saved)'
else
  project.save
  puts "Saved #{options[:project]}"
end
