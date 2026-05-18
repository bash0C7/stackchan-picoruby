require 'prism'
require 'tempfile'
require_relative 'ruby_class_extract/version'

module RubyClassExtract
  module_function

  def load_classes_from(path, exclude_superclasses: [])
    source = File.read(path)
    result = Prism.parse(source)
    raise "parse error: #{result.errors}" unless result.success?

    extracted = collect_class_module_source(result.value, exclude_superclasses)
    tmpfile = Tempfile.new(['ruby_class_extract', '.rb'])
    tmpfile.write(extracted.join("\n"))
    tmpfile.close
    load tmpfile.path
    nil
  end

  def collect_class_module_source(node, exclude_superclasses)
    out = []
    walk(node, exclude_superclasses, out)
    out
  end

  def walk(node, exclude_superclasses, out)
    return unless node.respond_to?(:child_nodes)

    case node
    when Prism::ClassNode
      sup = node.superclass
      sup_name = sup.respond_to?(:slice) ? sup.slice : nil
      return if sup_name && exclude_superclasses.include?(sup_name)
      out << node.slice
    when Prism::ModuleNode
      out << node.slice
    else
      node.child_nodes.compact.each do |child|
        walk(child, exclude_superclasses, out)
      end
    end
  end
end
