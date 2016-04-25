module Puppet::Pops
module Types

# @api private
class RubyGenerator < TypeFormatter
  def remove_common_namespace(namespace_segments, name)
    segments = name.split(TypeFormatter::NAME_SEGMENT_SEPARATOR)
    namespace_segments.size.times do |idx|
      break if segments.empty? || namespace_segments[idx] != segments[0]
      segments.shift
    end
    segments
  end

  def namespace_relative(namespace_segments, name)
    remove_common_namespace(namespace_segments, name).join(TypeFormatter::NAME_SEGMENT_SEPARATOR)
  end

  def create_class(obj)
    @dynamic_classes ||= Hash.new do |hash, key|
      rp = key.resolved_parent
      parent_class = rp.is_a?(PObjectType) ? create_class(rp) : Object
      class_def = ''
      class_body(key, EMPTY_ARRAY, class_def)
      cls = Class.new(parent_class)
      cls.class_eval(class_def)
      cls.define_singleton_method(:_ptype) { return key }
      hash[key] = cls
    end
    @dynamic_classes[obj]
  end

  def module_definition(types, comment)
    object_types, aliased_types = types.partition { |type| type.is_a?(PObjectType) }
    impl_names = implementation_names(object_types)

    # extract common implementation module prefix
    common_prefix = []
    segmented_names = impl_names.map { |impl_name| impl_name.split(TypeFormatter::NAME_SEGMENT_SEPARATOR) }
    segments = segmented_names[0]
    segments.size.times do |idx|
      segment = segments[idx]
      break unless segmented_names.all? { |sn| sn[idx] == segment }
      common_prefix << segment
    end

    # Create class definition of all contained types
    bld = ''
    start_module(common_prefix, comment, bld)
    class_names = []
    object_types.each_with_index do |type, index|
      class_names << class_definition(type, common_prefix, bld, impl_names[index])
      bld << "\n"
    end

    aliases = Hash[aliased_types.map { |type| [type.name, type.resolved_type] }]
    end_module(common_prefix, aliases, class_names, bld)
    bld
  end

  def start_module(common_prefix, comment, bld)
    bld << '# ' << comment << "\n"
    common_prefix.each { |cp| bld << 'module ' << cp << "\n" }
  end

  def end_module(common_prefix, aliases, class_names, bld)
    # Emit registration of contained type aliases
    unless aliases.empty?
      bld << "Puppet::Pops::Pcore.register_aliases({\n"
      aliases.each { |name, type| bld << "  '" << name << "' => " << TypeFormatter.string(type.to_s) << "\n" }
      bld.chomp!(",\n")
      bld << "})\n\n"
    end

    # Emit registration of contained types
    unless class_names.empty?
      bld << "Puppet::Pops::Pcore.register_implementations(\n"
      class_names.each { |class_name| bld << '  ' << class_name << ",\n" }
      bld.chomp!(",\n")
      bld << ")\n\n"
    end
    bld.chomp!("\n")

    common_prefix.each { |cp| bld << "end\n" }
  end

  def implementation_names(object_types)
    object_types.map do |type|
      ir = Loaders.implementation_registry
      impl_name = ir.module_name_for_type(type)
      raise Puppet::Error, "Unable to create an instance of #{type.name}. No mapping exists to runtime object" if impl_name.nil?
      impl_name[0]
    end
  end

  def class_definition(obj, namespace_segments, bld, class_name)
    module_segments = remove_common_namespace(namespace_segments, class_name)
    leaf_name = module_segments.pop
    module_segments.each { |segment| bld << 'module ' << segment << "\n" }
    bld << 'class ' << leaf_name
    segments = class_name.split(TypeFormatter::NAME_SEGMENT_SEPARATOR)

    unless obj.parent.nil?
      ir = Loaders.implementation_registry
      parent_impl = ir.module_name_for_type(obj.parent)
      raise Puppet::Error, "Unable to create an instance of #{obj.parent.name}. No mapping exists to runtime object" if parent_impl.nil?
      bld << ' < ' << namespace_relative(segments, parent_impl[0])
    end

    bld << "\n"
    bld << "  def self._plocation\n"
    bld << "    loc = Puppet::Util.path_to_uri(\"\#{__FILE__}\")\n"
    bld << "    URI(\"#\{loc}?line=#\{__LINE__.to_i - 3}\")\n"
    bld << "  end\n"

    bld << "\n"
    bld << "  def self._ptype\n"
    bld << '    @_ptype ||= ' << namespace_relative(segments, obj.class.name) << ".new('" << obj.name << "', "
    bld << TypeFormatter.new.ruby_string('ref', 2, obj.i12n_hash(false)) << ")\n"
    bld << "  end\n"

    class_body(obj, segments, bld)

    bld << "end\n"
    module_segments.size.times { bld << "end\n" }
    module_segments << leaf_name
    module_segments.join(TypeFormatter::NAME_SEGMENT_SEPARATOR)
  end

  def class_body(obj, segments, bld)
    if obj.parent.nil?
      bld << "\n  include " << namespace_relative(segments, Puppet::Pops::Types::PuppetObject.name) << "\n\n" # marker interface
      bld << "  def self.ref(type_string)\n"
      bld << "    " << namespace_relative(segments, Puppet::Pops::Types::PTypeReferenceType.name) << ".new(type_string)\n"
      bld << "  end\n"
    end

    # Output constants
    constants, others = obj.attributes(true).values.partition { |a| a.kind == PObjectType::ATTRIBUTE_KIND_CONSTANT }
    constants = constants.select { |ca| ca.container.equal?(obj) }
    unless constants.empty?
      constants.each { |ca| bld << "\n  def self." << ca.name << "\n    _ptype['" << ca.name << "'].value\n  end\n" }
      constants.each { |ca| bld << "\n  def " << ca.name << "\n    self.class." << ca.name << "\n  end\n" }
    end

    init_params = others.reject { |a| a.kind == PObjectType::ATTRIBUTE_KIND_DERIVED }
    opt, non_opt = init_params.partition { |ip| ip.value? }

    # Output type safe hash constructor
    bld << "\n  def self.from_hash(i12n)\n"
    bld << '    ' << namespace_relative(segments, TypeAsserter.name) << '.assert_instance_of('
    bld << "'" << obj.label << " initializer', _ptype.i12n_type, i12n)\n"
    non_opt.each { |ip| bld << '    ' << ip.name << " = i12n['" << ip.name << "']\n" }
    opt.each { |ip| bld << '    ' << ip.name << " = i12n.fetch('" << ip.name << "') { _ptype['" << ip.name << "'].value }\n" }
    bld << '    new'
    unless init_params.empty?
      bld << '('
      non_opt.each { |a| bld << a.name << ', ' }
      opt.each { |a| bld << a.name << ', ' }
      bld.chomp!(', ')
      bld << ')'
    end
    bld << "\n  end\n"

    # Output type safe constructor
    bld << "\n  def self.create"
    if init_params.empty?
      bld << "\n    new"
    else
      bld << '('
      non_opt.each { |ip| bld << ip.name << ', ' }
      opt.each { |ip| bld << ip.name << ' = ' << "_ptype['#{ip.name}'].value" << ', ' }
      bld.chomp!(', ')
      bld << ")\n"
      bld << '    ta = ' << namespace_relative(segments, TypeAsserter.name) << "\n"
      bld << "    attrs = _ptype.attributes(true)\n"
      init_params.each do |a|
        bld << "    ta.assert_instance_of('" << a.container.name << '[' << a.name << ']'
        bld << "', attrs['" << a.name << "'].type, " << a.name << ")\n"
      end
      bld << '    new('
      non_opt.each { |a| bld << a.name << ', ' }
      opt.each { |a| bld << a.name << ', ' }
      bld.chomp!(', ')
      bld << ')'
    end
    bld << "\n  end\n"

    # Output initializer
    bld << "\n  def initialize"
    unless init_params.empty?
      bld << '('
      non_opt.each { |ip| bld << ip.name << ', ' }
      opt.each { |ip| bld << ip.name << ' = ' << "_ptype['#{ip.name}'].value" << ', ' }
      bld.chomp!(', ')
      bld << ')'
      unless obj.parent.nil?
        bld << "\n    super"
        super_args = (non_opt + opt).select { |ip| !ip.container.equal?(obj) }
        unless super_args.empty?
          bld << '('
          super_args.each { |ip| bld << ip.name << ', ' }
          bld.chomp!(', ')
          bld << ')'
        end
      end
    end
    bld << "\n"

    init_params.each { |a| bld << '    @' << a.name << ' = ' << a.name << "\n" if a.container.equal?(obj) }
    bld << "  end\n\n"

    # Output attr_readers
    others.each do |a|
      next unless a.container.equal?(obj)
      if a.kind == PObjectType::ATTRIBUTE_KIND_DERIVED || a.kind == PObjectType::ATTRIBUTE_KIND_GIVEN_OR_DERIVED
        bld << '  def ' << a.name << "\n"
        bld << "    raise Puppet::Error, \"no method is implemented for derived attribute #{a.label}\"\n"
        bld << "  end\n"
      else
        bld << '  attr_reader :' << a.name << "\n"
      end
    end

    # Output function placeholders
    obj.functions(false).each_value do |func|
      bld << "\n  def " << func.name << "(*args)\n"
      bld << "    # Placeholder for #{func.type}\n"
      bld << "    raise Puppet::Error, \"no method is implemented for #{func.label}\"\n"
      bld << "  end\n"
    end

    # output hash and equality
    include_class = obj.include_class_in_equality?
    if obj.equality.nil?
      eq_names = obj.attributes(false).values.select { |a| a.kind != PObjectType::ATTRIBUTE_KIND_CONSTANT }.map(&:name)
    else
      eq_names = obj.equality
    end

    unless eq_names.empty? && !include_class
      bld << "\n  def hash\n    "
      bld << 'super.hash ^ ' unless obj.parent.nil?
      if eq_names.empty?
        bld << "self.class.hash\n"
      else
        bld << '['
        bld << 'self.class, ' if include_class
        eq_names.each { |eqn| bld << '@' << eqn << ', ' }
        bld.chomp!(', ')
        bld << "].hash\n"
      end
      bld << "  end\n"

      bld << "\n  def eql?(o)\n"
      bld << "    super.eql?(o) &&\n" unless obj.parent.nil?
      bld << "    self.class.eql?(o.class) &&\n" if include_class
      eq_names.each { |eqn| bld << '    @' << eqn << '.eql?(o.' <<  eqn << ") &&\n" }
      bld.chomp!(" &&\n")
      bld << "\n  end\n"
    end
  end
end
end
end
