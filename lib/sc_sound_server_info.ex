defmodule SCSoundServer.Info.Group do
  use TypedStruct

  typedstruct do
    field(:id, integer, enforce: true)
    field(:children, list, enforce: true)
  end

  def map_preply([_nunused | list]) do
    {a, _} = make(list)
    a
  end

  def make([]) do
    {[], []}
  end

  def make(list) do
    [id | tail] = list

    [number | tail] = tail

    if(number < 0) do
      SCSoundServer.Info.Synth.make(id, tail)
    else
      if(number == 0) do
        {%SCSoundServer.Info.Group{id: id, children: []}, tail}
      else
        {children, tail} =
          Enum.reduce(1..number, {[], tail}, fn _i, {out, tail} ->
            {g, tail} = SCSoundServer.Info.Group.make(tail)
            {out ++ [g], tail}
          end)

        {%SCSoundServer.Info.Group{id: id, children: children}, tail}
      end
    end
  end
end

defmodule SCSoundServer.Info.Synth do
  use TypedStruct

  typedstruct do
    field(:id, integer, enforce: true)
    field(:name, atom, enforce: true)
    field(:arguments, list, enforce: true)
  end

  def make(id, list) do
    [name | tail] = list
    [number | tail] = tail
    {arguments, tail} = Enum.split(tail, number * 2)
    arguments = args_to_keylist(arguments)

    {%SCSoundServer.Info.Synth{id: id, name: String.to_atom(name), arguments: arguments}, tail}
  end

  def def_list_to_argument_rate_list(deflist) do
    Enum.map(
      deflist,
      fn {defname, def} ->
        rates =
          Enum.filter(def.ugens, fn n ->
            n.name == "AudioControl" ||
              n.name == "Control" ||
              n.name == "TrigControl"
          end)
          |> Enum.sort(fn a, b -> a.special_index < b.special_index end)
          |> Enum.map(fn u ->
            {
              Enum.at(def.parameter_names, u.special_index).name,
              case u.rate do
                2 -> :audio
                1 -> :control
                0 -> :scalar
              end
            }
          end)

        outrate =
          Enum.filter(
            def.ugens,
            fn n ->
              String.contains?(n.name, "Out") && n.name != "LocalOut"
            end
          )
          |> Enum.map(fn u ->
            case u.rate do
              2 -> :audio
              1 -> :control
              0 -> :scalar
            end
          end)
          |> List.first()

        {defname, [rates: rates, outrate: outrate]}
      end
    )
  end

  def args_to_keylist(arguments) do
    Enum.chunk_every(arguments, 2)
    |> Enum.map(fn [k, v] -> {String.to_atom(k), v} end)
  end
end

defmodule SCSoundServer.Info do
  def find_used_audio_bus(%SCSoundServer.Info.Group{children: c}) do
    List.flatten(Enum.map(c, fn x -> find_used_audio_bus(x) end))
  end

  def find_used_audio_bus(%SCSoundServer.Info.Synth{arguments: a}) do
    Enum.filter(a, fn {_k, v} -> is_binary(v) end)
    |> Enum.filter(fn {_k, v} -> String.starts_with?(v, "a") end)
    |> Enum.map(fn {k, v} ->
      <<_::binary-size(1), rest::binary>> = v
      {k, String.to_integer(rest)}
    end)
  end

  def find_used_control_bus(%SCSoundServer.Info.Group{children: c}) do
    List.flatten(Enum.map(c, fn x -> find_used_control_bus(x) end))
  end

  def find_used_control_bus(%SCSoundServer.Info.Synth{arguments: a}) do
    Enum.filter(a, fn {_k, v} -> is_binary(v) end)
    |> Enum.filter(fn {_k, v} -> String.starts_with?(v, "c") end)
    |> Enum.map(fn {k, v} ->
      <<_::binary-size(1), rest::binary>> = v
      {k, String.to_integer(rest)}
    end)
  end

  def find_last_synth_writing_on_two_audio_busses(
        bus_int,
        other_bus_int,
        %SCSoundServer.Info.Group{
          children: c
        },
        def_arg_rates
      ) do
    c
    |> Enum.reverse()
    |> Enum.map(fn x ->
      if(def_arg_rates[x.name][:outrate] == :audio) do
        find_last_synth_writing_on_two_busses(bus_int, other_bus_int, x)
      else
        []
      end
    end)
    |> List.flatten()
    |> List.first()
  end

  def find_last_synth_writing_on_two_control_busses(
        bus_int,
        other_bus_int,
        %SCSoundServer.Info.Group{
          children: c
        },
        def_arg_rates
      ) do
    c
    |> Enum.reverse()
    |> Enum.map(fn x ->
      if(def_arg_rates[x.name][:outrate] == :control) do
        find_last_synth_writing_on_two_busses(bus_int, other_bus_int, x)
      else
        []
      end
    end)
    |> List.flatten()
    |> List.first()
  end

  def find_last_synth_writing_on_two_busses(
        bus_int,
        other_bus_int,
        s = %SCSoundServer.Info.Synth{}
      ) do
    v = s.arguments[:out]

    if(v == bus_int || v == other_bus_int) do
      s.id
    else
      []
    end
  end

  def find_last_synth_writing_on_audio_bus(
        bus_int,
        info_tree,
        def_arg_rates
      ) do
    List.first(find_synth_writing_on_audio_bus(bus_int, info_tree, def_arg_rates))
  end

  def find_synth_writing_on_audio_bus(
        bus_int,
        %SCSoundServer.Info.Group{children: c},
        def_arg_rates
      ) do
    List.flatten(
      Enum.map(Enum.reverse(c), fn x ->
        if(:audio == def_arg_rates[x.name][:outrate]) do
          find_synth_writing_on_audio_bus(bus_int, x)
        else
          []
        end
      end)
    )
  end

  def find_synth_writing_on_audio_bus(
        bus_int,
        s = %SCSoundServer.Info.Synth{name: _name, arguments: a}
      ) do
    Enum.filter(a, fn {k, _v} ->
      String.starts_with?(Atom.to_string(k), "out")
    end)
    |> Enum.map(fn {_k, v} ->
      if(v == bus_int, do: s, else: [])
    end)
  end

  def find_last_synth_writing_on_control_bus(
        bus_int,
        info_tree,
        def_arg_rates
      )
      when is_list(def_arg_rates) do
    List.first(find_synth_writing_on_control_bus(bus_int, info_tree, def_arg_rates))
  end

  def find_synth_writing_on_control_bus(
        bus_int,
        %SCSoundServer.Info.Group{children: c},
        def_arg_rates
      )
      when is_list(def_arg_rates) do
    List.flatten(
      Enum.map(Enum.reverse(c), fn x ->
        if(:control == def_arg_rates[x.name][:outrate]) do
          find_synth_writing_on_control_bus(bus_int, x)
        else
          []
        end
      end)
    )
  end

  def find_synth_writing_on_control_bus(
        bus_int,
        s = %SCSoundServer.Info.Synth{name: _name, arguments: a}
      ) do
    Enum.filter(a, fn {k, _v} ->
      String.starts_with?(Atom.to_string(k), "out")
    end)
    |> Enum.map(fn {_k, v} ->
      if(v == bus_int, do: s, else: [])
    end)
  end

  def find_synth(test_fun, synth = %SCSoundServer.Info.Synth{}) do
    if test_fun.(synth) do
      synth
    else
      false
    end
  end

  def find_synth(_test_fun, []) do
    false
  end

  def find_synth(test_fun, [first | rest]) do
    r = find_synth(test_fun, first)

    if(r == false) do
      find_synth(test_fun, rest)
    else
      r
    end
  end

  def find_synth(test_fun, %SCSoundServer.Info.Group{children: c}) do
    find_synth(test_fun, c)
  end

  def find_synth_by_id(synth_id, info_tree) do
    find_synth(&(&1.id == synth_id), info_tree)
  end

  def find_synth_by_name(name, info_tree) do
    find_synth(&(&1.name == name), info_tree)
  end

  def find_synth_reading_bus(bus_id, info_tree) do
    find_synth(&Enum.member?(&1.arguments, bus_id), info_tree)
  end

  def find_used_busses_r(
        synth_info = %SCSoundServer.Info.Synth{arguments: a},
        def_arg_rates,
        used_busses
      ) do
    outrate = def_arg_rates[synth_info.name][:outrate]

    {_out, bus_int} =
      Enum.find(a, fn {k, _v} -> String.starts_with?(Atom.to_string(k), "out") end)

    bus_int =
      if(synth_info.name == "outmixer") do
        0.0
      else
        bus_int
      end

    if Enum.member?(used_busses[outrate], bus_int / 1) do
      ins_from_bus = Enum.filter(synth_info.arguments, fn {_k, v} -> is_binary(v) end)

      used_busses =
        Enum.reduce(ins_from_bus, used_busses, fn {_k, v}, used_busses ->
          <<rate, rest::binary>> = v
          # c == 99
          # a == 97
          if(rate == 99) do
            put_in(
              used_busses[:control],
              MapSet.put(used_busses[:control], String.to_integer(rest) / 1)
            )
          else
            put_in(
              used_busses[:audio],
              MapSet.put(used_busses[:audio], String.to_integer(rest) / 1)
            )
          end
        end)

      used_busses
    else
      used_busses
    end
  end

  def find_used_busses_r(
        %SCSoundServer.Info.Group{children: c},
        def_arg_rates,
        used_busses
      ) do
    Enum.reverse(c)
    |> Enum.reduce(used_busses, fn s, used_busses ->
      find_used_busses_r(s, def_arg_rates, used_busses)
    end)
  end

  def find_used_busses(
        info_tree,
        def_arg_rates
      ) do
    used_busses = [audio: MapSet.new([0.0]), control: MapSet.new([])]

    find_used_busses_r(
      info_tree,
      def_arg_rates,
      used_busses
    )
  end
end
