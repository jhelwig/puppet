require 'spec_helper'
require 'puppet_spec/files'
require 'puppet/pops'
require 'puppet/loaders'
require 'puppet_spec/compiler'

describe 'FileBased module loader' do
  include PuppetSpec::Files

  let(:static_loader) { Puppet::Pops::Loader::StaticLoader.new() }
  let(:loaders) { Puppet::Pops::Loaders.new(Puppet::Node::Environment.create(:testing, [])) }

  it 'can load a 4x function API ruby function in global name space' do
    module_dir = dir_containing('testmodule', {
      'lib' => {
        'puppet' => {
          'functions' => {
            'foo4x.rb' => <<-CODE
               Puppet::Functions.create_function(:foo4x) do
                 def foo4x()
                   'yay'
                 end
               end
            CODE
          }
            }
          }
        })

    module_loader = Puppet::Pops::Loader::ModuleLoaders.module_loader_from(static_loader, loaders, 'testmodule', module_dir)
    function = module_loader.load_typed(typed_name(:function, 'foo4x')).value

    expect(function.class.name).to eq('foo4x')
    expect(function.is_a?(Puppet::Functions::Function)).to eq(true)
  end

  it 'can load a 4x function API ruby function in qualified name space' do
    module_dir = dir_containing('testmodule', {
      'lib' => {
        'puppet' => {
          'functions' => {
            'testmodule' => {
              'foo4x.rb' => <<-CODE
                 Puppet::Functions.create_function('testmodule::foo4x') do
                   def foo4x()
                     'yay'
                   end
                 end
              CODE
              }
            }
          }
      }})

    module_loader = Puppet::Pops::Loader::ModuleLoaders.module_loader_from(static_loader, loaders, 'testmodule', module_dir)
    function = module_loader.load_typed(typed_name(:function, 'testmodule::foo4x')).value
    expect(function.class.name).to eq('testmodule::foo4x')
    expect(function.is_a?(Puppet::Functions::Function)).to eq(true)
  end

  it 'system loader has itself as private loader' do
    module_loader = loaders.puppet_system_loader
    expect(module_loader.private_loader).to be(module_loader)
  end

  it 'makes parent loader win over entries in child' do
    module_dir = dir_containing('testmodule', {
      'lib' => { 'puppet' => { 'functions' => { 'testmodule' => {
        'foo.rb' => <<-CODE
           Puppet::Functions.create_function('testmodule::foo') do
             def foo()
               'yay'
             end
           end
        CODE
      }}}}})
    module_loader = Puppet::Pops::Loader::ModuleLoaders.module_loader_from(static_loader, loaders, 'testmodule', module_dir)

    module_dir2 = dir_containing('testmodule2', {
      'lib' => { 'puppet' => { 'functions' => { 'testmodule2' => {
        'foo.rb' => <<-CODE
           raise "should not get here"
        CODE
      }}}}})
    module_loader2 = Puppet::Pops::Loader::ModuleLoaders::FileBased.new(module_loader, loaders, 'testmodule2', module_dir2, 'test2')

    function = module_loader2.load_typed(typed_name(:function, 'testmodule::foo')).value

    expect(function.class.name).to eq('testmodule::foo')
    expect(function.is_a?(Puppet::Functions::Function)).to eq(true)
  end

  def typed_name(type, name)
    Puppet::Pops::Loader::TypedName.new(type, name)
  end

  context 'when loading' do
    include PuppetSpec::Compiler

    let(:testing_env) do
      {
        'testing' => {
          'modules' => modules,
          'manifests' => manifests
        }
      }
    end

    let(:manifests) { {} }
    let(:environments_dir) { Puppet[:environmentpath] }

    let(:testing_env_dir) do
      dir_contained_in(environments_dir, testing_env)
      env_dir = File.join(environments_dir, 'testing')
      PuppetSpec::Files.record_tmp(env_dir)
      env_dir
    end

    let(:modules_dir) { File.join(testing_env_dir, 'modules') }
    let(:env) { Puppet::Node::Environment.create(:testing, [modules_dir]) }
    let(:node) { Puppet::Node.new('test', :environment => env) }
    let(:logs) { [] }
    let(:warnings) { logs.select { |log| log.level == :warning }.map { |log| log.message } }
    let(:notices) { logs.select { |log| log.level == :notice }.map { |log| log.message } }

    context 'tasks' do
      let(:compiler) { Puppet::Parser::Compiler.new(node) }

      let(:modules) do
        { 'testmodule' => testmodule }
      end

      def compile(code = nil)
        Puppet[:code] = code
        Puppet::Util::Log.with_destination(Puppet::Test::LogCollector.new(logs)) do
          compiler.compile do |catalog|
            yield if block_given?
            catalog
          end
        end
      end

      context 'without metadata' do
        let(:testmodule) {
          {
            'tasks' => {
              'hello' => <<-RUBY
            require 'json'
            args = JSON.parse(STDIN.read)
            puts({message: args['message']}.to_json)
            exit 0
            RUBY
            }
          }
        }

        it 'loads task as a GenericTask subtype' do
          compile do
            module_loader = Puppet.lookup(:loaders).find_loader('testmodule')
            task_t = module_loader.load(:type, 'testmodule::hello')
            expect(task_t).to be_a(Puppet::Pops::Types::PObjectType)
            expect(task_t.name).to eq('Testmodule::Hello')
            expect(task_t.parent.name).to eq('GenericTask')

            task = task_t.create('foo' => 'the foo', 'fee' => 311, 'fum' => false)
            expect(task).to be_a(Puppet::Pops::Types::Task)
            expect(task.executable_path).to eql("#{modules_dir}/testmodule/tasks/hello")
            expect(task.task_json).to eql('{"foo":"the foo","fee":311,"fum":false}')
          end
        end

        it 'evaluator loads and notices an empty GenericTask' do
          compile(<<-PUPPET.unindent)
            notice(Testmodule::Hello({}))
          PUPPET
          expect(notices).to eql(["Testmodule::Hello({})"])
        end

        it 'evaluator loads and notices a GenericTask with parameters' do
          compile(<<-PUPPET.unindent)
            notice(Testmodule::Hello({foo => 'the foo', fee => 311, fum => false}))
          PUPPET
          expect(notices).to eql(["Testmodule::Hello({'foo' => 'the foo', 'fee' => 311, 'fum' => false})"])
       end
      end

      context 'with metadata' do
        let(:testmodule) {
          {
            'tasks' => {
              'hello.rb' => <<-RUBY,
            require 'json'
            args = JSON.parse(STDIN.read)
            puts({message: args['message']}.to_json)
            exit 0
            RUBY
            'hello.json' => <<-JSON
            {
              "supports_noop": true,
              "parameters": {
                 "message": {
                   "type": "String"
                 },
                 "font": {
                   "type": "Optional[String]"
                 }
            }}
            JSON
            }
          }
        }

        it 'loads a task with parameters as a Task subtype' do
          compile do
            module_loader = Puppet.lookup(:loaders).find_loader('testmodule')
            task_t = module_loader.load(:type, 'testmodule::hello')
            expect(task_t).to be_a(Puppet::Pops::Types::PObjectType)
            expect(task_t.name).to eq('Testmodule::Hello')
            expect(task_t.parent.name).to eq('Task')

            expect(task_t['message']).to be_a(Puppet::Pops::Types::PObjectType::PAttribute)
            expect(task_t['message'].type).to be_a(Puppet::Pops::Types::PStringType)
            expect(task_t['supports_noop']).to be_a(Puppet::Pops::Types::PObjectType::PAttribute)
            expect(task_t['supports_noop'].type).to be_a(Puppet::Pops::Types::PBooleanType)
            expect(task_t['supports_noop'].kind).to eql('constant')
            expect(task_t['supports_noop'].value).to eql(true)

            task = task_t.create('a message')
            expect(task).to be_a(Puppet::Pops::Types::Task)
            expect(task.executable_path).to eql("#{modules_dir}/testmodule/tasks/hello.rb")
            expect(task.task_json).to eql('{"message":"a message"}')
          end
        end

        it 'evaluator loads and notices a Task with positional parameters' do
          compile(<<-PUPPET.unindent)
            notice(Testmodule::Hello('a message'))
          PUPPET
          expect(notices).to eql(["Testmodule::Hello({'message' => 'a message'})"])
        end

        it 'evaluator loads and notices a Task with positional parameters' do
          compile(<<-PUPPET.unindent)
            notice(Testmodule::Hello('a message', 'helvetica'))
          PUPPET
          expect(notices).to eql(["Testmodule::Hello({'message' => 'a message', 'font' => 'helvetica'})"])
        end

        it 'evaluator fails on invalid number of parameters' do
          expect { compile(<<-PUPPET.unindent) }.to raise_error(/expects between 1 and 2 arguments, got 3/)
            notice(Testmodule::Hello('a message', 'helvetica', 'bold'))
          PUPPET
        end

        it 'evaluator loads and notices a Task with named parameters' do
          compile(<<-PUPPET.unindent)
            notice(Testmodule::Hello({message => 'a message'}))
          PUPPET
          expect(notices).to eql(["Testmodule::Hello({'message' => 'a message'})"])
        end

        it 'evaluator fails on invalid parameter names' do
          expect { compile(<<-PUPPET.unindent) }.to raise_error(/expects a value for key 'message'.*unrecognized key 'echo'/m)
            notice(Testmodule::Hello({echo => 'a message'}))
          PUPPET
        end

        context 'that has a malformed top-level entry' do
          let(:testmodule) {
            {
              'tasks' => {
                'hello' => 'echo hello',
                'hello.json' => <<-JSON
                {
                  "supports_nop": true,
                  "parameters": {
                     "message": { "type": "String" }
                  }
                }
              JSON
              }
            }
          }

          it 'loads a task with parameters as a Task subtype' do
            compile do
              module_loader = Puppet.lookup(:loaders).find_loader('testmodule')
              expect{module_loader.load(:type, 'testmodule::hello')}.to raise_error(
                /The metadata for task testmodule::hello has wrong type, unrecognized key 'supports_nop'/)
            end
          end
        end

        context 'that has a malformed parameter name' do
          let(:testmodule) {
            {
              'tasks' => {
                'hello' => 'echo hello',
                'hello.json' => <<-JSON
                {
                  "supports_noop": true,
                  "parameters": {
                     "Message": { "type": "String" }
                  }
                }
              JSON
              }
            }
          }

          it 'loads a task with parameters as a Task subtype' do
            compile do
              module_loader = Puppet.lookup(:loaders).find_loader('testmodule')
              expect{module_loader.load(:type, 'testmodule::hello')}.to raise_error(
                /entry 'parameters' key of entry 'Message' expects a match for Pattern\[\/\\A\[a-z\]\[a-z0-9_\]\*\\z\/\], got 'Message'/)
            end
          end
        end
      end

      context 'with defined type' do
        let(:testmodule) {
          {
            'tasks' => {
              'hello.rb' => <<-RUBY,
            require 'json'
            args = JSON.parse(STDIN.read)
            puts({message: args['message']}.to_json)
            exit 0
            RUBY
            },
            'types' => {
              'hello.pp' => <<-PUPPET
            type Testmodule::Hello = Task {
              constants => {
                supports_noop => true,
                executable => 'hello.rb'
              },
              attributes => {
                message => String,
                font => {
                  type => Optional[String],
                  value => undef
                }
              }
            }
            PUPPET
            }
          }
        }

        it 'loads a task defined as a Type' do
          compile do
            module_loader = Puppet.lookup(:loaders).find_loader('testmodule')
            task_t = module_loader.load(:type, 'testmodule::hello').resolve(module_loader)
            expect(task_t).to be_a(Puppet::Pops::Types::PObjectType)
            expect(task_t.name).to eq('Testmodule::Hello')
            task = task_t.create('a message')
            expect(task.executable_path).to eql("#{modules_dir}/testmodule/tasks/hello.rb")
          end
        end

        it 'evaluator loads and notices a Task with named parameters' do
          compile(<<-PUPPET.unindent)
            notice(Testmodule::Hello({message => 'a message'}))
          PUPPET
          expect(notices).to eql(["Testmodule::Hello({'message' => 'a message'})"])
        end
      end
    end

    context 'module function and class using a module type alias' do
      let(:modules) do
        {
          'mod' => {
            'functions' => {
              'afunc.pp' => <<-PUPPET.unindent
                function mod::afunc(Mod::Analias $v) {
                  notice($v)
                }
            PUPPET
            },
            'types' => {
              'analias.pp' => <<-PUPPET.unindent
                 type Mod::Analias = Enum[a,b]
                 PUPPET
            },
            'manifests' => {
              'init.pp' => <<-PUPPET.unindent
                class mod(Mod::Analias $v) {
                  notify { $v: }
                }
                PUPPET
            }
          }
        }
      end

      # The call to mod:afunc will load the function, and as a consequence, make an attempt to load
      # the parameter type Mod::Analias. That load in turn, will trigger the Runtime3TypeLoader which
      # will load the manifests in Mod. The init.pp manifest also references the Mod::Analias parameter
      # which results in a recursive call to the same loader. This test asserts that this recursive
      # call is handled OK.
      # See PUP-7391 for more info.
      it 'should handle a recursive load' do
        expect(eval_and_collect_notices("mod::afunc('b')", node)).to eql(['b'])
      end
    end
  end
end
