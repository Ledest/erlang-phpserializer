% Takes a serialized php object and turns it into an erlang data structure
% This module is heavily inspired by Richard Jones
% Read more here: http://www.metabrew.com/article/reading-serialized-php-objects-from-erlang

-module(php_serializer).

-export([serialize/1, unserialize/1]).

serialize(null) -> <<"N;">>;
serialize(true) -> <<"b:1;">>;
serialize(false) -> <<"b:0;">>;
serialize(Item) when is_binary(Item)->
    <<"s:", (integer_to_binary(len(Item)))/binary, $:, (escape_binary(Item))/binary, $;>>;
serialize(Item) when is_float(Item)-> <<"d:", (float_to_binary(Item, [{decimals, 17}, compact]))/binary, $;>>;
serialize(Item) when is_integer(Item)-> <<"i:", (integer_to_binary(Item))/binary, $;>>;
%% Now the fun begins!!
serialize(Item) when is_list(Item) -> serialize(Item, <<"a:", (integer_to_binary(length(Item)))/binary, ":{">>);
serialize(Item) when is_atom(Item) -> serialize(atom_to_binary(Item, latin1)).

serialize([{Key, Value}|List], Acc) ->
    serialize(List, <<Acc/binary, (serialize(Key))/binary, (serialize(Value))/binary>>);
serialize([], Acc) -> <<Acc/binary, $}>>.

escape_binary(Bin) -> <<$", Bin/binary, $">>.

unserialize(Value) ->
    case unserialize(Value, []) of
        {[Result], []} -> Result;
        Result -> Result
    end.

unserialize(<<"a:", Rest/binary>>, Acc) ->
    [ArrayLengthBin, Rest1] = binary:split(Rest, <<":{">>),
    case unserialize(Rest1, []) of
        {error, _Reason} = Error -> Error;
        {ArrayElements, Rest2} ->
            case binary_to_integer(ArrayLengthBin) * 2 =:= length(ArrayElements) of
                true -> unserialize(Rest2, [make_pairs(ArrayElements)|Acc]);
                _false -> {error, "Invalid items length in array"}
            end
    end;
unserialize(<<$}, Rest/binary>>, Acc) -> {Acc, Rest};
unserialize(<<"s:", Rest/binary>>, Acc) ->
    [BinStringLength, Rest1] = binary:split(Rest, <<$:>>),
    [_, String, Rest2] = re:split(Rest1, <<"^\"(.{", BinStringLength/binary, "})\";">>),
    unserialize(Rest2, [String|Acc]);
unserialize(<<"b:0;", Rest/binary>>, Acc) -> unserialize(Rest, [false|Acc]);
unserialize(<<"b:1;", Rest/binary>>, Acc) -> unserialize(Rest, [true|Acc]);
unserialize(<<"i:", Rest/binary>>, Acc) ->
    [BinaryInteger, Rest1] = binary:split(Rest, <<$;>>),
    unserialize(Rest1, [binary_to_integer(BinaryInteger)|Acc]);
unserialize(<<"d:", Rest/binary>>, Acc) ->
    [BinaryDecimal, Rest1] = binary:split(Rest, <<$;>>),
    unserialize(Rest1, [binary_to_float(BinaryDecimal) | Acc]);
unserialize(<<"N;", Rest/binary>>, Acc) -> unserialize(Rest, [null|Acc]);
unserialize(<<"O:", _Rest/binary>>, _Acc) -> {error, "Unserializing classes not implemented"};
unserialize(<<>>, Acc) -> {Acc, []}.

-ifdef(HAVE_string__length_1).
len(Data) -> string:length(Data).
-else.
len(Data) -> length(unicode:characters_to_list(Data)).
-endif.

make_pairs(List) -> make_pairs(List, []).

make_pairs([V, K|T], Acc) -> make_pairs(T, [{K, V}|Acc]);
make_pairs([], Acc) -> Acc.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
unserialize_test() ->
    ?assertEqual(455, unserialize(<<"i:455;">>)),
    ?assertEqual(<<"0123456789">>, unserialize(<<"s:10:\"0123456789\";">>)),
    ?assertEqual(<<"foo">>, unserialize(<<"s:3:\"foo\";">>)),
    ?assertEqual(true, unserialize(<<"b:1;">>)),
    ?assertEqual(false, unserialize(<<"b:0;">>)),
    ?assertEqual([{0, <<"foo">>}], unserialize(<<"a:1:{i:0;s:3:\"foo\";}">>)),
    ?assertEqual([{0, <<"foobar">>}, {1, 1234}, {2, true}],
                 unserialize(<<"a:3:{i:0;s:6:\"foobar\";i:1;i:1234;i:2;b:1;}">>)),
    ?assertEqual([{0, [{0, <<"foobar">>}]}, {1, 420}],
                 unserialize(<<"a:2:{i:0;a:1:{i:0;s:6:\"foobar\";}i:1;i:420;}">>)),
    ?assertEqual([{<<"foo">>, [{0, 242}, {1, null}]}],
                 unserialize(<<"a:1:{s:3:\"foo\";a:2:{i:0;i:242;i:1;N;}}">>)),
    ?assertEqual(
        [{<<"barfoo">>, [{0, <<"foobar">>}, {1, 1234}, {2, false}]}, {0, 11234}, {<<"bar">>, <<"foo">>}],
        unserialize(<<"a:3:{s:6:\"barfoo\";a:3:{i:0;s:6:\"foobar\";i:1;i:1234;i:2;b:0;}",
                      "i:0;i:11234;s:3:\"bar\";s:3:\"foo\";}">>)
    ),
    ?assertEqual({error, "Unserializing classes not implemented"}, unserialize(<<"O:3:\"foo\":0:{}">>)),
    ?assertEqual({error, "Invalid items length in array"}, unserialize(<<"a:10:{i:32;}">>)),
    BigString = <<"a:7:{s:3:\"eid\";i:12345;s:6:\"secret\";s:15:\"abcdefgjijklmno\";s:8:\"testmode\"",
                   ";N;s:15:\"ordercost_range\";a:2:{s:4:\"mode\";s:3:\"all\";s:9:\"intervals\";a:1:",
                   "{i:14;a:2:{s:3:\"min\";N;s:3:\"max\";N;}}}s:21:\"disable_deliv_address\";b:0;s:",
                   "11:\"orderstatus\";N;s:9:\"active_SE\";b:1;}">>,
    Expected = [
        {<<"eid">>, 12345},
        {<<"secret">>, <<"abcdefgjijklmno">>},
        {<<"testmode">>, null},
        {<<"ordercost_range">>, [
            {<<"mode">>, <<"all">>},
            {<<"intervals">>, [
                {14, [
                    {<<"min">>, null},
                    {<<"max">>, null}
                ]}
            ]}
        ]},
        {<<"disable_deliv_address">>, false},
        {<<"orderstatus">>, null},
        {<<"active_SE">>, true}
    ],
    Result = unserialize(BigString),
    ?assertEqual(Expected, Result).

serialize_test() ->
    ?assertEqual(<<"s:6:\"Foobar\";">>, serialize(<<"Foobar">>)),
    ?assertEqual(<<"d:10.00009999999999976;">>, serialize(10.0001)),
    ?assertEqual(<<"N;">>, serialize(null)),
    ?assertEqual(<<"b:1;">>, serialize(true)),
    ?assertEqual(<<"b:0;">>, serialize(false)),
    BigList = [
        {<<"eid">>, 12345},
        {<<"secret">>, <<"abcdefgjijklmno">>},
        {<<"testmode">>, null},
        {<<"ordercost_range">>, [
            {<<"mode">>, <<"all">>},
            {<<"intervals">>, [
                {14, [
                    {<<"min">>, null},
                    {<<"max">>, null}
                ]}
            ]}
        ]},
        {<<"disable_deliv_address">>, false},
        {<<"orderstatus">>, null},
        {<<"active_SE">>, true}
    ],
    Expected = <<"a:7:{s:3:\"eid\";i:12345;s:6:\"secret\";s:15:\"abcdefgjijklmno\";s:8:\"testmode\"",
                   ";N;s:15:\"ordercost_range\";a:2:{s:4:\"mode\";s:3:\"all\";s:9:\"intervals\";a:1:",
                   "{i:14;a:2:{s:3:\"min\";N;s:3:\"max\";N;}}}s:21:\"disable_deliv_address\";b:0;s:",
                   "11:\"orderstatus\";N;s:9:\"active_SE\";b:1;}">>,
    Result = serialize(BigList),
    ?assertEqual(Expected, Result).

combined_test_() ->
    List = [<<"a">>, 1, 1.0, null, []],
    Proplist = lists:zip(lists:seq(0, length(List) - 1), List),
    Values = [<<"a">>, 1, 1.0, null, [], Proplist],
    [?_assertEqual(Value, unserialize(serialize(Value))) || Value <- Values].

encode_string_with_quotes_test() ->
    TestVar = [{<<"secret">>, <<"Foo \"bar\"">>}],
    Result = serialize(TestVar),
    Result2 = unserialize(Result),
    ?assertEqual(TestVar, Result2),
    ok.

encode_large_lists_test() ->
    List = lists:zip(lists:seq(0, 11), lists:seq(0, 11)),
    Unpacked = unserialize(serialize(List)),
    ?assertEqual(List, Unpacked),
    ok.

encode_complex_structure_test() ->
    List = [{<<"a">>, [
                {<<"aa">>, [
                    {<<"aaa">>, [
                        {<<"aaaa">>, 1}
                    ]}
                ]},
                {<<"ab">>, [
                    {<<"abb">>, [
                        {<<"abbb">>, 1},
                        {<<"abbb2">>, 2}
                    ]},
                    {<<"abb2">>, [
                        {<<"abb2b">>, 1}
                    ]}
                ]}
             ]}
           ],
    Recoded = unserialize(serialize(List)),
    ?assertEqual(List, Recoded),
    ok.

-endif.
