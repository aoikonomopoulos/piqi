(*pp camlp4o -I `ocamlfind query piqi.syntax` pa_labelscope.cmo pa_openin.cmo *)
(*
   Copyright 2009, 2010, 2011, 2012 Anton Lavrik

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*)


module T = Piqi_piqi


module Record = T.Record
module Field = T.Field
module Variant = T.Variant
module Option = T.Option
module Enum = T.Enum
module Alias = T.Alias


module Import = T.Import
module Includ = T.Includ
module Extend = T.Extend
module Any = T.Any


module R = Record
module F = Field
module V = Variant
module O = Option
module E = Enum
module A = Alias
module L = T.Piqi_list
module P = T.Piqi


module Config = Piqi_config
module Iolist = Piqi_iolist


module U = Piqi_util


(*
 * common global variables
 *)

(* provide default values automatically when loading data from various intput
 * formats: Piq, Wire, JSON *)
let resolve_defaults = ref false


(* lazily loaded representation of piqi-boot.piqi (see piqi.ml for details) *)
let piqi_boot :T.piqi option ref = ref None


(*
 * Common functions
 *)

(* Run a function with a specific resolve_defauls setting. The global
 * "resolve_defaults" variable is preserved *)
let with_resolve_defaults new_resolve_defaults f =
  U.with_bool resolve_defaults new_resolve_defaults f


let is_boot_piqi p =
  match !piqi_boot with
    | None -> false
    | Some x -> p == x


(* TODO: move more of this stuff to piqi_util.ml and leave only Piqi-specific
 * functions here *)
let some_of = function
  | Some x -> x
  | None -> assert false


let flatmap f l =  List.concat (List.map f l)


let find_dups l =
  let rec aux = function
    | [] -> None
    | h::t ->
        try 
          let dup = List.find (fun x -> x = h) t in
          Some (dup, h)
        with Not_found -> aux t
  in aux l


let quote s = "\"" ^ s ^ "\""


(* NOTE: naive, non-tail recursive. Remove duplicates from the list using
 * reference equality, preserves the initial order *)
let rec uniqq = function
  | [] -> []
  | h::t ->
      let t = uniqq t in
      if List.memq h t then t else h :: t


(* leave the first of the duplicate elements in the list instead of the last *)
let uniqq l =
  List.rev (uniqq (List.rev l))


let rec uniq = function
  | [] -> []
  | h::t ->
      let t = uniq t in
      if List.mem h t then t else h :: t


(* leave the first of the duplicate elements in the list instead of the last *)
let uniq l =
  List.rev (uniq (List.rev l))


let get_parent (typedef:T.typedef) :T.namespace =
  let parent =
    match typedef with
      | `record t -> t.R#parent
      | `variant t -> t.V#parent
      | `enum t -> t.E#parent
      | `alias t -> t.A#parent
      | `list t -> t.L#parent
  in
  some_of parent


let set_parent (def:T.typedef) (parent:T.namespace) =
  let parent = Some parent in
  match def with
    | `record x -> x.R#parent <- parent
    | `variant x -> x.V#parent <- parent
    | `enum x -> x.E#parent <- parent
    | `alias x -> x.A#parent <- parent
    | `list x -> x.L#parent <- parent


let get_parent_piqi (def:T.typedef) :T.piqi =
  let parent = get_parent def in
  match parent with
    | `import x -> some_of x.Import#piqi
    | `piqi x -> x


let typedef_name (typedef:T.typedef) =
  let res =
    match typedef with
      | `record x -> x.R#name
      | `variant x -> x.V#name
      | `enum x -> x.E#name
      | `alias x -> x.A#name
      | `list x -> x.L#name
  in
  some_of res


let piqi_typename (t:T.piqtype) =
  let open T in
  (* XXX: built-in types should't be used at that stage *)
  match t with
    | `int -> "int"
    | `float -> "float"
    | `bool -> "bool"
    | `string -> "string"
    | `binary -> "binary"
    | `any -> "piqi-any"
    | #T.typedef as x -> typedef_name x


let full_piqi_typename x =
  let name = piqi_typename x in
  match x with
    | #T.typedef as def ->
        let piqi = get_parent_piqi def in
        if is_boot_piqi piqi
        then name
        else
          let parent_name = some_of piqi.P#modname in
          parent_name ^ "/" ^ name
    | _ -> (* built-in type *)
        (* XXX: normally built-in types should be used at the time when this
         * funciton is used *)
        name


let name_of_field f =
  let open T.Field in
  match f.name, f.piqtype with
    | Some n, _ -> n
    | None, Some t -> piqi_typename t
    | _ when f.typename <> None -> (* field type hasn't been resolved yet *)
        Piqi_name.get_local_name (some_of f.typename)
    | _ -> assert false


let name_of_option o =
  let open T.Option in
  match o.name, o.piqtype with
    | Some n, _ -> n
    | None, Some t -> piqi_typename t
    | _ when o.typename <> None -> (* option type hasn't been resolved yet *)
        Piqi_name.get_local_name (some_of o.typename)
    | _ -> assert false


let rec unalias = function
  | `alias t ->
      let t = some_of t.T.Alias#piqtype in
      unalias t
  | t -> t


let is_typedef t =
  match unalias t with
    | #T.typedef -> true
    | _ -> false


let is_primitive_piqtype t =
  match unalias t with
    | `enum _ -> true
    | #T.typedef -> false
    | _ -> true


(* is record or list or alias of the two *)
let is_container_type t =
  match unalias t with
    | (#T.typedef as t) ->
        (match t with
          | `record _ | `list _ -> true
          | _ -> false
        )
    | _ -> false


(* check if the module is a Piqi self-specification, i.e. it is
 * "piqi.org/piqi" or includes it *)
let is_self_spec (piqi: T.piqi) =
  (* XXX: cache this information to avoid computing it over and over again *)
  List.exists
    (fun x -> x.P#modname = Some "piqi.org/piqi")
    piqi.P#included_piqi


(* check if any of the module's definitions depends on "piqi-any" type *)
let depends_on_piqi_any (piqi: T.piqi) =
  let aux x =
    let is_any x =
      (unalias x) = `any
    in
    let is_any_opt = function
      | Some x -> is_any x
      | None -> false
    in
    match x with
      | `record x -> List.exists (fun x -> is_any_opt x.F#piqtype) x.R#field
      | `variant x -> List.exists (fun x -> is_any_opt x.O#piqtype) x.V#option
      | `list x -> is_any (some_of x.L#piqtype)
      | `enum _ -> false
      | `alias _ -> false (* don't check aliases, we do unalias instead *)
  in
  List.exists aux piqi.P#resolved_typedef


(* 
 * error reporting, printing and handling
 *)

let string_of_loc (file, line, col) =
  file ^ ":" ^ string_of_int line ^ ":" ^ string_of_int col


let strerr loc s = 
  string_of_loc loc ^ ": " ^ s


let string_of_exn exn =
  Printexc.to_string exn
  (* this is not supported in all runtime modes, and it is not compatible with
   * OCaml 3.10 *)
  (*
  Printexc.to_string exn ^ " ; backtrace: " ^ Printexc.get_backtrace ()
  *)


(* piq/piqi language error *)
exception Error of Piqloc.loc * string 


(* piqi utility error *)
exception Piqi_error of string

let piqi_error s =
  raise (Piqi_error s)

let piqi_warning s =
  prerr_endline ("Warning: " ^ s)


let error_at loc s =
  (*
  failwith (strerr loc s)
  *)
  raise (Error (loc, s))


let reference f x =
  Piqloc.reference f x


let location obj =
  try
    if !Config.debug_level > 0
    then
      Piqloc.trace_find obj
    else
      Piqloc.find obj
  with
    Not_found -> ("unknown", 0, 0)


let error obj s =
  let loc = location obj in
  error_at loc s


let error_string obj s =
  let loc = location obj in
  strerr loc s


let warning obj s =
  let loc = location obj in
  if not !Config.flag_no_warnings
  then prerr_endline ("Warning: " ^ strerr loc s)


let trace_indent = ref 0

let print_trace_indent () =
  for i = 1 to !trace_indent
  do
    prerr_string "    "
  done


let eprintf_if cond fmt =
  if cond
  then
    begin
      print_trace_indent ();
      Printf.fprintf stderr fmt
    end
  else Printf.ifprintf stderr fmt


let debug fmt =
  eprintf_if (!Config.debug_level > 0) fmt


let trace fmt =
  eprintf_if (!Config.flag_trace || !Config.debug_level > 0)  fmt


let trace_enter () =
  incr trace_indent


let trace_leave x =
  decr trace_indent;
  x

