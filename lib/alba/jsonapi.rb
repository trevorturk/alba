module Alba
  # JSON:API
  module JSONAPI
    JSONAPI_DSLS = {_id: nil, _type: nil, _meta: nil, _links: {}}.freeze
    private_constant :JSONAPI_DSLS

    ID_AND_TYPE = [:id, :type].freeze
    private_constant :ID_AND_TYPE

    class Association < ::Alba::Association
      @const_cache = {}
      class << self
        attr_reader :const_cache
      end

      attr_reader :meta, :links

      def initialize(name:, condition: nil, resource: nil, nesting: nil, meta: nil, links: nil, &block)
        super(name: name, condition: condition, resource: resource, nesting: nesting, &block)
        @meta = meta
        @links = links
      end
    end

    # @api private
    def self.included(base)
      base.include Alba::Resource
      base.class_eval do
        # Initialize
        JSONAPI_DSLS.each do |name, initial|
          instance_variable_set("@#{name}", initial.dup) unless instance_variable_defined?("@#{name}")
        end
      end
      base.layout(inline: jsonapi_proc)
      base.attributes(:id, :type)
      base.extend Alba::JSONAPI::ClassMethods
      base.prepend(Alba::JSONAPI::InstanceMethods)
      super
    end

    # For JSON:API layout
    def self.jsonapi_proc
      proc do
        result = {data: jsonapi_data}
        result[:meta] = @meta if @meta
        result[:included] = included_data if params[:include]
        result[:links] = @links if @links
        result
      end
    end

    # Instance method called from jsonapi_proc
    module InstanceMethods
      def initialize(object, params: {}, within: Alba::Resource::WITHIN_DEFAULT, meta: nil, links: nil)
        JSONAPI_DSLS.each_key { |name| instance_variable_set("@#{name}", self.class.__send__(name)) }
        super(object, params: params, within: within, meta: meta)

        @_links.transform_keys! { |k| transform_key(k) } if Alba.inferring
        @links = if Alba.inferring
                   links&.transform_keys { |k| transform_key(k) }
                 else
                   links
                 end
      end

      def to_h
        jsonapi_data
      end

      private

      def jsonapi_data
        collection? ? data_for_collection : data_for_single_object
      end

      def data_for_collection
        object.map do |o|
          resource_for(o)
        end
      end

      def data_for_single_object
        resource_for(object)
      end

      def resource_for(obj)
        result = identifier_for(obj)
        result[:attributes] = plain_attributes(obj) if has_attributes
        result[:relationships] = relationships(obj) if has_relationships
        result[:meta] = instance_eval(&@_meta) if @_meta
        result[:links] = @_links.transform_values { |l| instance_exec(obj, &l) } unless @_links.empty?
        result
      end

      def identifier_for(obj)
        if obj.respond_to?(:included_modules) && obj.included_modules.include?(Alba::Resource)
          {type: obj.name, id: obj.object.id}
        else
          {type: type(obj), id: id(obj)}
        end
      end

      def has_attributes
        true # TODO
      end

      def has_relationships
        true # TODO
      end

      def type(_obj)
        t = self.class._type || fetch_key
        Alba.inferring ? transform_key(t) : t
      end

      def id(obj)
        self.class._id ? obj.__send__(self.class._id) : obj.id
      end

      # Filter plain attributes for `attributes` section in JSONAPI
      def plain_attributes(obj)
        attrs = attributes.select do |k, v|
          (v.is_a?(Symbol) || (v.is_a?(Array) && v.first.is_a?(Symbol))) && !ID_AND_TYPE.include?(k) # TODO: Bad code
        end
        h = {}
        attrs.each do |key, attribute|
          set_key_and_attribute_body_from(obj, key, attribute, h)
        end
        h
      end

      # Filter relationships for `relationships` section in JSONAPI
      def relationships(obj)
        associations = attributes.select do |_k, v|
          (v.is_a?(Array) && v.first.is_a?(Alba::Association)) || v.is_a?(Alba::Association)
        end
        associations.filter_map do |key, assoc|
          value = assoc.is_a?(Array) ? conditional_relationship(obj, key, assoc) : relationship(obj, key, assoc)
          value == Alba::Resource::CONDITION_UNMET ? nil : value
        end.to_h
      end

      # TODO: Similar code to `conditional_attribute`, consider refactoring
      def conditional_relationship(obj, key, assoc)
        condition = assoc.last
        if condition.is_a?(Proc)
          conditional_relationship_with_proc(obj, key, assoc.first, condition)
        else
          conditional_relationship_with_symbol(obj, key, assoc.first, condition)
        end
      end

      # TODO: Similar code to `conditional_attribute_with_proc`, consider refactoring
      def conditional_relationship_with_proc(obj, key, assoc, condition)
        arity = condition.arity
        # We can return early to skip
        return Alba::Resource::CONDITION_UNMET if arity <= 1 && !instance_exec(obj, &condition)

        fetched_relationship = relationship(obj, key, assoc)
        return Alba::Resource::CONDITION_UNMET if arity >= 2 && !instance_exec(obj, assoc.object, &condition)

        fetched_relationship
      end

      def conditional_relationship_with_symbol(obj, key, assoc, condition)
        return CONDITION_UNMET unless __send__(condition)

        relationship(obj, key, assoc)
      end

      def relationship(obj, key, assoc)
        data = {'data' => data_for_relationship(obj, assoc)}
        data[:meta] = assoc.meta.call(obj) if assoc.meta
        data[:links] = get_links(obj, assoc.links) if assoc.links
        key = transform_key(key)
        [key, data]
      end

      def data_for_relationship(obj, association)
        data = fetch_attribute(obj, nil, association)
        type = association.name.to_s.delete_suffix('s').to_sym # TODO: use inflector
        slice_data = lambda do |h|
          next if h.nil? # Circular association

          h.slice!(*ID_AND_TYPE)
          h[:type] = type if h[:type].nil?
          h
        end
        data.is_a?(Array) ? data.map(&slice_data) : slice_data.call(data)
      end

      def get_links(obj, links)
        case links
        when Symbol
          obj.__send__(links)
        when Hash
          links.transform_values do |l|
            get_link(obj, l)
          end
        else
          raise Alba::Error, "Unknown link format: #{links.inspect}"
        end
      end

      def get_link(obj, link)
        if link.is_a?(Proc)
          instance_exec(obj, &link)
        else # Symbol
          obj.__send__(link)
        end
      end

      def included_data
        Array(params[:include]).filter_map do |inc|
          assoc = @_attributes.find do |k, v|
            ((v.is_a?(Array) && v.first.is_a?(Alba::Association)) || v.is_a?(Alba::Association)) && (k.name.to_sym == inc.to_sym)
          end
          next unless assoc

          fetch_attribute(object, nil, assoc.last)
        end.flatten
      end
    end

    # Additional DSL
    module ClassMethods
      attr_reader(*JSONAPI_DSLS.keys)

      # @private
      def inherited(subclass)
        JSONAPI_DSLS.each_key { |name| subclass.instance_variable_set("@#{name}", instance_variable_get("@#{name}").clone) }
        super
      end

      def association(name, condition = nil, resource: nil, key: nil, meta: nil, links: nil, **options)
        nesting = self.name&.rpartition('::')&.first
        assoc = ::Alba::JSONAPI::Association.new(name: name, condition: condition, resource: resource, nesting: nesting, meta: meta, links: links)
        @_attributes[key&.to_sym || name.to_sym] = options[:if] ? [assoc, options[:if]] : assoc
      end
      alias one association
      alias many association
      alias has_one association
      alias has_many association

      def set_id(id)
        @_id = id
      end

      def set_type(type)
        @_type = type
      end

      def link(name, &block)
        @_links[name] = block
      end
    end
  end
end
