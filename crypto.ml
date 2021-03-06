(* Scott Dickson (sdd48)
 * Charles Yu (ccy27)
 * Zack Brienza (zb5)
 * Aaron Wisner (daw268)
*)

open String

(* Number base for the string form of the keys *)
type key = Big_int.big_int

(* Various constants for string parsing and encrypting/ descrypting *)
let chunk_size = 128
let key_size = 200
let max_length = 2*key_size + 1
let output_chunk_size = max_length + 1
let chunk_size_char = Char.chr chunk_size |> String.make 1


(* Aliases for common functions used in working with Big_ints *)
let zero = Big_int.zero_big_int
let bMod = Big_int.mod_big_int
let eq = Big_int.eq_big_int
let add = Big_int.add_big_int
let add_i = Big_int.add_int_big_int
let sub = Big_int.sub_big_int
let mult = Big_int.mult_big_int
let mult_i = Big_int.mult_int_big_int
let div = Big_int.div_big_int
let half b = div b (Big_int.big_int_of_int 2)
let decr b = add b (Big_int.big_int_of_int (-1))
let even b = eq (bMod b (Big_int.big_int_of_int 2)) zero
let of_int = Big_int.big_int_of_int
let to_int = Big_int.int_of_big_int
let of_string = Big_int.big_int_of_string
let to_string = Big_int.string_of_big_int

(* Constants for this version of the RSA algorithm. *)
let b = of_int 256
let exp = of_int 17

(* Functions to be fed to a Functor to form
 * a hastable involving keys *)
let key_equal = eq
let key_hash k = bMod k (of_int max_int) |> to_int


(***** HELPER FUNCTIONS *****)

(* Requires: s:string of length >0*)
(* Returns: the highest index character in s*)
let last_char s =
  get s (length s - 1)

(* Requires: s:string of length >0*)
(* Returns: s without its highest index character *)
let strip_last s =
  String.sub s 0 (String.length s - 1)


(* Requires: keys a,b, and m *)
(* Returns: a^b mod m while avoiding overflow *)
let rec mod_exp a b m =
  if eq b zero then of_int 1 else
  if even b then
    let v = add (mod_exp a (half b) m) m in
    let x = bMod v m in bMod (mult x x) m
  else
    let v = add (mod_exp a (decr b) m) m in
    bMod (mult (bMod a m)  (bMod v m)) m


(* Requires: key n *)
(* Returns: whether n is prime. Based on the fermat test *)
let is_prime n =
  let x1 = of_int 17 in (* {1,..,n-1} *)
  let x2 = of_int 31 in
  eq (mod_exp x1 (decr n) n) (of_int 1) &&
  eq (mod_exp x2 (decr n) n) (of_int 1)


(* Extended euclidean algorithm. Adapted from the wikibooks
 page on the algorithm *)
let rec egcd a b m=
  if eq a zero then (b, zero, of_int 1)
  else let (g,y,x) = egcd (bMod b a) a m in
  (g,sub x (mult (div b a) y), y)

(* Requires a,m of type key *)
(* Returns: a^(-1) mod m, if it exists. Otherwise raise and exception *)
let modinv a m =
  let (g,x,y) = egcd a m m in
  if not (eq g (of_int 1)) then failwith "No inverse"
    else let x' = bMod x m in
  if Big_int.lt_big_int x' zero then add x' m else x'


(* Given a string of any ascii characters return its
 * Big_int representation by treating a string as a base 256 integer
 * where each character correspons to a digit with its ascii code as value *)
let rec string_to_large_int s =
  if s = "" then zero else
  add_i (last_char s |> Char.code)
    (mult b (string_to_large_int (strip_last s)) )



(* Recursive helper function implemeneting the functionality of
 * large_int_to_string *)
let rec large_int_to_string' n s=
  if eq n zero then s else
  let r = bMod n b in
  large_int_to_string'
  (div (sub n r) b) ((to_int r |> Char.chr |> String.make 1)^s)

(* Given a Big_int convert it to a string representation by converting the
 * Big_int to a base 256 integer and creating a string where character i
 * is the character represented by ascii code of digit i in that base
 * 256 representation of the number. *)
let large_int_to_string n = large_int_to_string' n ""

(* Aliases for .mli function *)
let string_from_key = to_string

let key_from_string = of_string

(***** END HELPER FUNCTIONS *****)


(* Helper for the large random number generator. Generates a random digit
 * n times, appending them together. *)
let rec big_random' acc n =
  if n = 0 then Big_int.big_int_of_string acc
  else big_random' ((Random.int 10  |> string_of_int)^acc) (n-1)


(* Generate a random very large integer by the helper big_random' for some
 * set number of iterations and appending the results *)
let big_random () =
  big_random' "" key_size


(* Call the large random number generator repeatedly, check whether
 * it is prime, and if not search for another number. Once a prime is
 * found, return it. *)
let generate_key =
  Random.self_init ();
  let rec loop () =
    let p = big_random () in
    if is_prime p && not (eq (bMod (decr p) exp) zero) then p else loop ()
  in loop

(* Generate two large prime number and let their product *)
let generate_public_private ()=
  let x = generate_key () in
  let y = generate_key () in
   (mult x y ,x)


(* Pad to make sure packet length = output chunk size *)
let encrypt_line s pu =
  mod_exp (string_to_large_int s) exp pu |> large_int_to_string

let decrypt_line s pu pr =
  let pr' = div pu pr in
  let k' = modinv exp (mult (decr pr') (decr pr)) in
  let s' = string_to_large_int s in
  mod_exp s' k' pu |> large_int_to_string


(* Pads zero characters onto s until len(S) = l *)
let rec zero_pad s l =
  if String.length s < l then
  zero_pad ((String.make 1 '\000')^s) l
  else s

(* Given a string s either strip character or pad zeros until
 * Length s = l *)
let rec fix_length s l =
  if String.length s > l then
  fix_length (String.sub s 1 (String.length s - 1)) l
  else if String.length s < l then
  fix_length ((String.make 1 '\000')^s) l
  else s


(* Given a string s of size chunk_size or less and the target device's public
 * key,  encrypt its data and pad the result with zero character, labeleding
 * the result with another character indicating the length of the original data.
 *)
let encrypt_and_chunk s pu =
    let lead_chr = (String.length s) |> Char.chr |> String.make 1 in
    let enc = zero_pad (encrypt_line s pu) max_length in
    (lead_chr)^enc


(* Given a string s of size output_chunk_size  and a public key, private key
 * pair extract the data size from the first character, decrypt
 * the remainder of the string
 * and strip the result to match the desired size. *)
let decrypt_chunked s pu pr =
  let size = Char.code s.[0] in
  let dec = decrypt_line (String.sub s 1 (String.length s - 1)) pu pr in
  fix_length dec size
