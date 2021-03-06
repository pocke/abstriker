require "abstriker/version"
require "set"
require "ripper"

module Abstriker
  class NotImplementedError < NotImplementedError
    attr_reader :subclass, :abstract_method

    def initialize(klass, abstract_method)
      super("#{abstract_method} is abstract, but not implemented by #{klass}")
      @subclass = klass
      @abstract_method = abstract_method
    end
  end

  class SexpTraverser
    def initialize(sexp)
      @sexp = sexp
    end

    def traverse(current_sexp = nil, parent = nil, &block)
      sexp = current_sexp || @sexp
      first = sexp[0]
      if first.is_a?(Symbol) # node
        yield sexp, parent
        args = Ripper::PARSER_EVENT_TABLE[first]
        return if args.nil? || args.zero?

        args.times do |i|
          param = sexp[i + 1]
          if param.is_a?(Array)
            traverse(param, sexp, &block)
          end
        end
      else # array
        sexp.each do |n|
          if n.is_a?(Array)
            traverse(n, sexp, &block)
          end
        end
      end
    end
  end

  @disable = false

  def self.disable=(v)
    @disable = v
  end

  def self.disabled?
    @disable
  end

  def self.enabled?
    !disabled?
  end

  def self.abstract_methods
    @abstract_methods ||= {}
  end

  def self.sexps
    @sexps ||= {}
  end

  def self.extended(base)
    base.extend(SyntaxMethods)
    base.singleton_class.extend(SyntaxMethods)
    if enabled?
      base.extend(ModuleMethods) if base.is_a?(Module)
      base.extend(ClassMethods) if base.is_a?(Class)
    end
  end

  module SyntaxMethods
    private

    def abstract(symbol)
      method_set = Abstriker.abstract_methods[self] ||= Set.new
      method_set.add(instance_method(symbol))
    end

    def abstract_singleton_method(symbol)
      method_set = Abstriker.abstract_methods[singleton_class] ||= Set.new
      method_set.add(singleton_class.instance_method(symbol))
    end
  end

  module HookBase
    private

    def call_at_outer_class_definition?(klass, trace_event, method_name)
      if trace_event.event == :c_return && trace_event.self == klass && trace_event.method_id == method_name
        traverser = SexpTraverser.new(Abstriker.sexps[trace_event.path])
        traverser.traverse do |n, parent|
          if n[0] == :@ident && n[1] == method_name.to_s && n[2][0] == trace_event.lineno
            if parent[0] == :command || parent[0] == :fcall
              # include Mod
            elsif parent[0] == :command_call || parent[0] == :call
              if parent[1][0] == :var_ref && parent[1][1][0] == :@kw && parent[1][1][1] == "self"
                # self.include Mod
                return false
              else
                # unknown case
                return true
              end
            else
              return true
            end
          end
        end
      end

      false
    end

    def check_abstract_methods(klass)
      return if Abstriker.disabled?

      unless klass.instance_variable_get("@__abstract_trace_point")
        tp = TracePoint.trace(:end, :c_return, :raise) do |t|
          if t.event == :raise
            tp.disable
            next
          end

          t_self = t.self

          target_class_end = t_self == klass && t.event == :end
          target_class_new_end = (t_self == Class || t_self == Module) && t.event == :c_return && t.method_id == :new && t.return_value == klass
          include_at_outer = call_at_outer_class_definition?(klass, t, :include)
          if target_class_end || target_class_new_end || include_at_outer
            klass.ancestors.drop(1).each do |mod|
              Abstriker.abstract_methods[mod]&.each do |fmeth|
                meth = klass.instance_method(fmeth.name) rescue nil
                if meth.nil? || meth.owner == mod
                  tp.disable
                  klass.instance_variable_set("@__abstract_trace_point", nil)
                  raise Abstriker::NotImplementedError.new(klass, fmeth)
                end
              end
            end
            tp.disable
            klass.instance_variable_set("@__abstract_trace_point", nil)
          end

          extend_at_outer = call_at_outer_class_definition?(klass, t, :extend)
          if target_class_end || target_class_new_end || extend_at_outer
            klass.singleton_class.ancestors.drop(1).each do |mod|
              Abstriker.abstract_methods[mod]&.each do |fmeth|
                meth = klass.singleton_class.instance_method(fmeth.name) rescue nil
                if meth.nil? || meth.owner == mod
                  tp.disable
                  klass.instance_variable_set("@__abstract_trace_point", nil)
                  raise Abstriker::NotImplementedError.new(klass, fmeth)
                end
              end
            end
            tp.disable
            klass.instance_variable_set("@__abstract_trace_point", nil)
          end
        end
        klass.instance_variable_set("@__abstract_trace_point", tp)
      end
    end
  end

  module ClassMethods
    include HookBase

    private

    def inherited(subclass)
      check_abstract_methods(subclass)
    end
  end

  module ModuleMethods
    include HookBase

    private

    def included(base)
      super
      return if Abstriker.disabled?

      caller_info = caller_locations(1, 1)[0]

      unless Abstriker.sexps[caller_info.absolute_path]
        Abstriker.sexps[caller_info.absolute_path] ||= Ripper.sexp(File.read(caller_info.absolute_path))
      end
      check_abstract_methods(base)
    end
    alias_method :extended, :included
  end
end
