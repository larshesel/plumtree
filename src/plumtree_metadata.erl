%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(plumtree_metadata).

-export([get/2,
         get/3,
         fold/3,
         fold/4,
         to_list/1,
         to_list/2,
         iterator/1,
         iterator/2,
         itr_next/1,
         itr_close/1,
         itr_done/1,
         itr_key_values/1,
         itr_key/1,
         itr_values/1,
         itr_value/1,
         itr_default/1,
         prefix_hash/1,
         put/3,
         put/4,
         delete/2,
         delete/3,
         cleanup/2,
         cleanup_all/1]).

-include("plumtree_metadata.hrl").

-export_type([iterator/0]).

%% Get Option Types
-type get_opt_default_val() :: {default, metadata_value()}.
-type get_opt_resolver()    :: {resolver, metadata_resolver()}.
-type get_opt_allow_put()   :: {allow_put, boolean()}.
-type get_opt()             :: get_opt_default_val() | get_opt_resolver() | get_opt_allow_put().
-type get_opts()            :: [get_opt()].

%% Iterator Types
-type it_opt_resolver()     :: {resolver, metadata_resolver() | lww}.
-type it_opt_default_fun()  :: fun((metadata_key()) -> metadata_value()).
-type it_opt_default()      :: {default, metadata_value() | it_opt_default_fun()}.
-type it_opt_keymatch()     :: {match, term()}.
-type it_opt()              :: it_opt_resolver() | it_opt_default() | it_opt_keymatch().
-type it_opts()             :: [it_opt()].
-type fold_opts()           :: it_opts().
-type iterator()            :: {plumtree_metadata_manager:metadata_iterator(), it_opts()}.

%% Put Option Types
-type put_opts()            :: [].

%% Delete Option types
-type delete_opts()         :: [].

-define(TOMBSTONE, '$deleted').

%% @doc same as get(FullPrefix, Key, [])
-spec get(metadata_prefix(), metadata_key()) -> metadata_value() | undefined.
get(FullPrefix, Key) ->
    get(FullPrefix, Key, []).

%% @doc Retrieves the local value stored at the given prefix and key.
%%
%% get/3 can take the following options:
%%  * default: value to return if no value is found, `undefined' if not given.
%%  * resolver:  A function that resolves conflicts if they are encountered. If not given
%%               last-write-wins is used to resolve the conflicts
%%  * allow_put: whether or not to write and broadcast a resolved value. defaults to `true'.
%%
%% NOTE: an update will be broadcast if conflicts are resolved and
%% `allow_put' is `true'. any further conflicts generated by
%% concurrenct writes during resolution are not resolved
-spec get(metadata_prefix(), metadata_key(), get_opts()) -> metadata_value().
get({Prefix, SubPrefix}=FullPrefix, Key, Opts)
  when (is_binary(Prefix) orelse is_atom(Prefix)) andalso
       (is_binary(SubPrefix) orelse is_atom(SubPrefix)) ->
    PKey = prefixed_key(FullPrefix, Key),
    Default = get_option(default, Opts, undefined),
    ResolveMethod = get_option(resolver, Opts, lww),
    AllowPut = get_option(allow_put, Opts, true),
    case plumtree_metadata_manager:get(PKey) of
        undefined -> Default;
        Existing ->
            maybe_tombstone(maybe_resolve(PKey, Existing, ResolveMethod, AllowPut), Default)
    end.

%% @doc same as fold(Fun, Acc0, FullPrefix, []).
-spec fold(fun(({metadata_key(),
                 [metadata_value() | metadata_tombstone()] |
                 metadata_value() | metadata_tombstone()}, any()) -> any()),
           any(),
           metadata_prefix()) -> any().
fold(Fun, Acc0, FullPrefix) ->
    fold(Fun, Acc0, FullPrefix, []).

%% @doc Fold over all keys and values stored under a given prefix/subprefix. Available
%% options are the same as those provided to iterator/2.
-spec fold(fun(({metadata_key(),
                 [metadata_value() | metadata_tombstone()] |
                 metadata_value() | metadata_tombstone()}, any()) -> any()),
           any(),
           metadata_prefix(),
           fold_opts()) -> any().
fold(Fun, Acc0, FullPrefix, Opts) ->
    It = iterator(FullPrefix, Opts),
    fold_it(Fun, Acc0, It).

fold_it(Fun, Acc, It) ->
    case itr_done(It) of
        true ->
            ok = itr_close(It),
            Acc;
        false ->
            Next = Fun(itr_key_values(It), Acc),
            fold_it(Fun, Next, itr_next(It))
    end.

%% @doc same as to_list(FullPrefix, [])
-spec to_list(metadata_prefix()) -> [{metadata_key(),
                                      [metadata_value() | metadata_tombstone()] |
                                      metadata_value() | metadata_tombstone()}].
to_list(FullPrefix) ->
    to_list(FullPrefix, []).


%% @doc Return a list of all keys and values stored under a given prefix/subprefix. Available
%% options are the same as those provided to iterator/2.
-spec to_list(metadata_prefix(), fold_opts()) -> [{metadata_key(),
                                                   [metadata_value() | metadata_tombstone()] |
                                                   metadata_value() | metadata_tombstone()}].
to_list(FullPrefix, Opts) ->
    fold(fun({Key, ValOrVals}, Acc) ->
                 [{Key, ValOrVals} | Acc]
         end, [], FullPrefix, Opts).

%% @doc same as iterator(FullPrefix, []).
-spec iterator(metadata_prefix()) -> iterator().
iterator(FullPrefix) ->
    iterator(FullPrefix, []).

%% @doc Return an iterator pointing to the first key stored under a prefix
%%
%% iterator/2 can take the following options:
%%   * resolver: either the atom `lww' or a function that resolves conflicts if they
%%               are encounted (see get/3 for more details). Conflict resolution
%%               is performed when values are retrieved (see itr_value/1 and itr_key_values/1).
%%               If no resolver is provided no resolution is performed. The default is to
%%               not provide a resolver.
%%   * allow_put: whether or not to write and broadcast a resolved value. defaults to `true'.
%%   * default: Used when the value an iterator points to is a tombstone. default is
%%              either an arity-1 function or a value. If a function, the key the iterator
%%              points to is passed as the argument and the result is returned in place
%%              of the tombstone. If default is a value, the value is returned in place of
%%              the tombstone. This applies when using functions such as itr_values/1 and
%%              itr_key_values/1.
%%   * match: A tuple containing erlang terms and '_'s. Match can be used to iterate
%%            over a subset of keys -- assuming the keys stored are tuples
-spec iterator(metadata_prefix(), it_opts()) -> iterator().
iterator({Prefix, SubPrefix}=FullPrefix, Opts)
  when (is_binary(Prefix) orelse is_atom(Prefix)) andalso
       (is_binary(SubPrefix) orelse is_atom(SubPrefix)) ->
    KeyMatch = get_option(match, Opts, undefined),
    It = plumtree_metadata_manager:iterator(FullPrefix, KeyMatch),
    {It, Opts}.

%% @doc Advances the iterator
-spec itr_next(iterator()) -> iterator().
itr_next({It, Opts}) ->
    It1 = plumtree_metadata_manager:iterate(It),
    {It1, Opts}.

%% @doc Closes the iterator
-spec itr_close(iterator()) -> ok.
itr_close({It, _Ots}) ->
    plumtree_metadata_manager:iterator_close(It).

%% @doc Returns true if there is nothing more to iterate over
-spec itr_done(iterator()) -> boolean().
itr_done({It, _Opts}) ->
    plumtree_metadata_manager:iterator_done(It).

%% @doc Return the key and value(s) pointed at by the iterator. Before
%% calling this function, check the iterator is not complete w/ itr_done/1. If a resolver
%% was passed to iterator/0 when creating the given iterator, siblings will be resolved
%% using the given function or last-write-wins (if `lww' is passed as the resolver). If
%% no resolver was used then no conflict resolution will take place. If conflicts are
%% resolved, the resolved value is written to local metadata and a broadcast is submitted
%% to update other nodes in the cluster if `allow_put' is `true'. If `allow_put' is `false'
%% the values are resolved but are not written or broadcast. A single value is returned as the second
%% element of the tuple in the case values are resolved. If no resolution takes place then a list of
%% values will be returned as the second element (even if there is only a single sibling).
%%
%% NOTE: if resolution may be performed this function must be called at most once
%% before calling itr_next/1 on the iterator (at which point the function can be called
%% once more).
-spec itr_key_values(iterator()) -> {metadata_key(),
                                     [metadata_value() | metadata_tombstone()] |
                                     metadata_value() |
                                     metadata_tombstone()}.
itr_key_values({It, Opts}) ->
    Default = itr_default({It, Opts}),
    {Key, Obj} = plumtree_metadata_manager:iterator_value(It),
    AllowPut = get_option(allow_put, Opts, true),
    case get_option(resolver, Opts, undefined) of
        undefined ->
            {Key, maybe_tombstones(plumtree_metadata_object:values(Obj), Default)};
        Resolver ->
            Prefix = plumtree_metadata_manager:iterator_prefix(It),
            PKey = prefixed_key(Prefix, Key),
            Value = maybe_tombstone(maybe_resolve(PKey, Obj, Resolver, AllowPut), Default),
            {Key, Value}
    end.

%% @doc Return the key pointed at by the iterator. Before
%% calling this function, check the iterator is not complete w/ itr_done/1.
%% No conflict resolution will be performed as a result of calling this function.
-spec itr_key(iterator()) -> metadata_key().
itr_key({It, _Opts}) ->
    {Key, _} = plumtree_metadata_manager:iterator_value(It),
    Key.

%% @doc Return all sibling values pointed at by the iterator. Before
%% calling this function, check the iterator is not complete w/ itr_done/1.
%% No conflict resolution will be performed as a result of calling this function.
-spec itr_values(iterator()) -> [metadata_value() | metadata_tombstone()].
itr_values({It, Opts}) ->
    Default = itr_default({It, Opts}),
    {_, Obj} = plumtree_metadata_manager:iterator_value(It),
    maybe_tombstones(plumtree_metadata_object:values(Obj), Default).

%% @doc Return a single value pointed at by the iterator. If there are conflicts and
%% a resolver was specified in the options when creating this iterator, they will be
%% resolved. Otherwise, and error is returned. If conflicts are resolved, the resolved
%% value is written locally and a broadcast is performed to update other nodes
%% in the cluster if `allow_put' is `true' (the default value). If `allow_put' is `false',
%% values are resolved but not written or broadcast.
%%
%% NOTE: if resolution may be performed this function must be called at most once
%% before calling itr_next/1 on the iterator (at which point the function can be called
%% once more).
-spec itr_value(iterator()) -> metadata_value() | metadata_tombstone() | {error, conflict}.
itr_value({It, Opts}) ->
    Default = itr_default({It, Opts}),
    {Key, Obj} = plumtree_metadata_manager:iterator_value(It),
    AllowPut = get_option(allow_put, Opts, true),
    case get_option(resolver, Opts, undefined) of
        undefined ->
            case plumtree_metadata_object:value_count(Obj) of
                1 ->
                    maybe_tombstone(plumtree_metadata_object:value(Obj), Default);
                _ ->
                    {error, conflict}
            end;
        Resolver ->
            Prefix = plumtree_metadata_manager:iterator_prefix(It),
            PKey = prefixed_key(Prefix, Key),
            maybe_tombstone(maybe_resolve(PKey, Obj, Resolver, AllowPut), Default)
    end.

%% @doc Returns the value returned when an iterator points to a tombstone. If the default
%% used when creating the given iterator is a function it will be applied to the current
%% key the iterator points at. If no default was provided the tombstone value was returned.
%% This function should only be called after checking itr_done/1.
-spec itr_default(iterator()) -> metadata_tombstone() | metadata_value() | it_opt_default_fun().
itr_default({_, Opts}=It) ->
    case get_option(default, Opts, ?TOMBSTONE) of
        Fun when is_function(Fun) ->
            Fun(itr_key(It));
        Val -> Val
    end.

%% @doc Return the local hash associated with a full-prefix or prefix. The hash value is
%% updated periodically and does not always reflect the most recent value. This function
%% can be used to determine when keys stored under a full-prefix or prefix have changed.
%% If the tree has not yet been updated or there are no keys stored the given
%% (full-)prefix. `undefined' is returned.
-spec prefix_hash(metadata_prefix() | binary() | atom()) -> binary() | undefined.
prefix_hash(Prefix) when is_tuple(Prefix) or is_atom(Prefix) or is_binary(Prefix) ->
    plumtree_metadata_hashtree:prefix_hash(Prefix).

%% @doc same as put(FullPrefix, Key, Value, [])
-spec put(metadata_prefix(), metadata_key(), metadata_value() | metadata_modifier()) -> ok.
put(FullPrefix, Key, ValueOrFun) ->
    put(FullPrefix, Key, ValueOrFun, []).

%% @doc Stores or updates the value at the given prefix and key locally and then
%% triggers a broadcast to notify other nodes in the cluster. Currently, there
%% are no put options
%%
%% NOTE: because the third argument to this function can be a metadata_modifier(),
%% used to resolve conflicts on write, metadata values cannot be functions.
%% To store functions in metadata wrap them in another type like a tuple.
-spec put(metadata_prefix(),
          metadata_key(),
          metadata_value() | metadata_modifier(),
          put_opts()) -> ok.
put({Prefix, SubPrefix}=FullPrefix, Key, ValueOrFun, _Opts)
  when (is_binary(Prefix) orelse is_atom(Prefix)) andalso
       (is_binary(SubPrefix) orelse is_atom(SubPrefix)) ->
    PKey = prefixed_key(FullPrefix, Key),
    CurrentContext = current_context(PKey),
    Updated = plumtree_metadata_manager:put(PKey, CurrentContext, ValueOrFun),
    broadcast(PKey, Updated).

%% @doc same as delete(FullPrefix, Key, [])
-spec delete(metadata_prefix(), metadata_key()) -> ok.
delete(FullPrefix, Key) ->
    delete(FullPrefix, Key, []).

%% @doc Removes the value associated with the given prefix and key locally and then
%% triggers a broradcast to notify other nodes in the cluster. Currently there are
%% no delete options
%%
%% NOTE: currently deletion is logical and no GC is performed.
-spec delete(metadata_prefix(), metadata_key(), delete_opts()) -> ok.
delete(FullPrefix, Key, _Opts) ->
    put(FullPrefix, Key, ?TOMBSTONE, []).


-spec cleanup(metadata_prefix(), pos_integer()) -> ok | {error, any()}.
cleanup(FullPrefix, AgeInSecs) ->
    plumtree_metadata_cleanup:force_cleanup(FullPrefix, AgeInSecs).

-spec cleanup_all(metadata_prefix()) -> ok | {error, any()}.
cleanup_all(AgeInSecs) ->
    plumtree_metadata_cleanup:force_cleanup(AgeInSecs).


%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private
current_context(PKey) ->
    case plumtree_metadata_manager:get(PKey) of
        undefined -> plumtree_metadata_object:empty_context();
        CurrentMeta -> plumtree_metadata_object:context(CurrentMeta)
    end.

%% @private
maybe_resolve(PKey, Existing, Method, AllowPut) ->
    SibCount = plumtree_metadata_object:value_count(Existing),
    maybe_resolve(PKey, Existing, SibCount, Method, AllowPut).

%% @private
maybe_resolve(_PKey, Existing, 1, _Method, _AllowPut) ->
    plumtree_metadata_object:value(Existing);
maybe_resolve(PKey, Existing, _, Method, AllowPut) ->
    Reconciled = plumtree_metadata_object:resolve(Existing, Method),
    RContext = plumtree_metadata_object:context(Reconciled),
    RValue = plumtree_metadata_object:value(Reconciled),
    case AllowPut of
        false ->
            ok;
        true ->
            Stored = plumtree_metadata_manager:put(PKey, RContext, RValue),
            broadcast(PKey, Stored)
    end,
    RValue.

%% @private
maybe_tombstones(Values, Default) ->
    [maybe_tombstone(Value, Default) || Value <- Values].

%% @private
maybe_tombstone(?TOMBSTONE, Default) ->
    Default;
maybe_tombstone(Value, _Default) ->
    Value.

%% @private
broadcast(PKey, Obj) ->
    Broadcast = #metadata_broadcast{pkey = PKey,
                                    obj  = Obj},
    plumtree_broadcast:broadcast(Broadcast, plumtree_metadata_manager).

%% @private
-spec prefixed_key(metadata_prefix(), metadata_key()) -> metadata_pkey().
prefixed_key(FullPrefix, Key) ->
    {FullPrefix, Key}.

get_option(Key, Opts, Default) ->
    case lists:keyfind(Key, 1, Opts) of
        false -> Default;
        {_, Val} -> Val
    end.
