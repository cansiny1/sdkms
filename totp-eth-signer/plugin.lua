----------------- Constant --------------------
local MASTER_KEY =  "MASTER_KEY"

-- TOTP URLs will contain this value as `issuer`
local totp_issuer = "Fortanix DSM"

-- Security objects created for each account will have this prefix in their name
local totp_name_prefix = "totp/"

-- A trimmed down copy of basexx library, taken from:
-- https://github.com/aiq/basexx/blob/v0.4.1/lib/basexx.lua

local basexx = {}

local function divide_string(str, max)
  local result = {}
  local start = 1
  for i = 1, #str do
     if i % max == 0 then
        table.insert(result, str:sub(start, i))
        start = i + 1
     elseif i == #str then
        table.insert(result, str:sub(start, i))
     end
  end
  return result
end

local function number_to_bit(num, length)
  local bits = {}
  while num > 0 do
     local rest = math.floor(math.fmod(num, 2))
     table.insert(bits, rest)
     num = (num - rest) / 2
  end

  while #bits < length do
     table.insert(bits, "0")
  end
  return string.reverse(table.concat(bits))
end

local function ignore_set(str, set)
  if set then str = str:gsub("["..set.."]", "") end
  return str
end

local function pure_from_bit(str)
  return ( str:gsub( '........', function (cc) return string.char(tonumber(cc, 2)) end) )
end

local function unexpected_char_error(str, pos)
  local c = string.sub(str, pos, pos)
  return string.format("unexpected character at position %d: '%s'", pos, c)
end

function basexx.to_bit(str)
  local sub_fn = function(c)
    local byte = string.byte(c)
    local bits = {}
    for _ = 1,8 do
       table.insert(bits, byte % 2)
       byte = math.floor(byte / 2)
    end
    return table.concat(bits):reverse()
  end
  return ( str:gsub('.', sub_fn) )
end

local function from_basexx(str, alphabet, bits)
  local result = {}
  for i = 1, #str do
     local c = string.sub(str, i, i)
     if c ~= '=' then
        local index = string.find(alphabet, c, 1, true)
        if not index then
           return nil, unexpected_char_error(str, i)
        end
        table.insert(result, number_to_bit(index - 1, bits))
     end
  end
  local value = table.concat(result)
  local pad = #value % 8
  return pure_from_bit(string.sub(value, 1, #value - pad))
end

local function to_basexx(str, alphabet, bits, pad)
  local bitString = basexx.to_bit(str)
  local chunks = divide_string(bitString, bits)
  local result = {}
  for _,value in ipairs(chunks) do
     if ( #value < bits ) then
        value = value .. string.rep('0', bits - #value)
     end
     local pos = tonumber(value, 2) + 1
     table.insert(result, alphabet:sub(pos, pos))
  end
  table.insert(result, pad)
  return table.concat(result)
end

local base32Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
local base32PadMap = { "", "======", "====", "===", "=" }

function basexx.from_base32(str, ignore)
  str = ignore_set(str, ignore)
  return from_basexx(string.upper(str), base32Alphabet, 5)
end

function basexx.to_base32(str)
  return to_basexx(str, base32Alphabet, 5, base32PadMap[ #str % 5 + 1 ])
end

local base64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local base64PadMap = { "", "==", "=" }

function basexx.from_base64(str, ignore)
   str = ignore_set(str, ignore)
   return from_basexx(str, base64Alphabet, 6)
end

function basexx.to_base64(str)
   return to_basexx(str, base64Alphabet, 6, base64PadMap[ #str % 3 + 1 ])
end

-- OTP library adapted to use DSM for crypto
-- Source: https://github.com/remjey/luaotp/blob/v0.1-6/src/otp.lua

local otp = {}

local unpack = unpack or table.unpack

local metadata_format_version = 1
local default_key_length = 15
local default_hash_algorithm = "SHA1"
local default_digits = 6
local default_period = 30
local default_totp_deviation = 5

-- Formats a counter to a 8-byte string
local function counter_format(n)
  local rt = { 0, 0, 0, 0, 0, 0, 0, 0 }
  local i = 8
  while i > 1 and n > 0 do
    rt[i] = n % 0x100
    n = math.floor(n / 0x100)
    i = i - 1
  end
  return string.char(unpack(rt))
end

-- Generates a one-time password based on a key and a counter
local function generate_password(key_name, counter, digits, hash_alg)
  local c = counter_format(counter)
  local key = assert(Sobject { name = key_name })
  local mac_response = assert(key:mac { data = Blob.from_bytes(c), alg = hash_alg })
  local sign = { string.byte(mac_response.mac:bytes(), 1, 20) }
  local offset = 1 + sign[20] % 0x10
  local r = tostring(
    0x1000000 * (sign[offset] % 0x80) +
    0x10000 * (sign[offset + 1]) +
    0x100 * (sign[offset + 2]) +
    (sign[offset + 3])
  ):sub(-digits)
  if #r < digits then
    r = string.rep("0", digits - #r) .. r
  end
  return r
end

local function percent_encode_char(c)
  return string.format("%%%02X", c:byte())
end

local function url_encode(str)
  -- We use a temporary variable to discard the second result returned by gsub
  local r = str:gsub("[^a-zA-Z0-9.~_-]", percent_encode_char)
  return r
end

------ TOTP functions ------

local totpmt = {}

function otp.new_totp(account, key_length, digits, period, hash_alg)
  local r = {
    type = "totp",
    key_name = totp_name_prefix .. account,
    key_length = key_length or default_key_length,
    hash_alg = hash_alg or default_hash_algorithm,
    digits = digits or default_digits,
    period = period or default_period,
    counter = 0,
  }
  setmetatable(r, { __index = totpmt, __tostring = totpmt.metadata })
  return r
end

local function get_time(param)
  if type(param) == "string" then
    return Time.from_iso8601(param):unix_epoch_seconds()
  elseif type(param) == "number" then
    return param
  else
    return Time.now_insecure():unix_epoch_seconds()
  end
end

local function totp_generate_password(self, deviation, for_time)
  local counter = math.floor(get_time(for_time) / self.period) + (deviation or 0)
  return
    generate_password(self.key_name, counter, self.digits, self.hash_alg),
    counter
end

function totpmt:generate_password(deviation, for_time)
  local r = totp_generate_password(self, deviation, for_time)
  return r -- discard second value
end

function totpmt:verify(code, accepted_deviation, for_time)
  if #code ~= self.digits then return false end
  local ad = accepted_deviation or default_totp_deviation
  for d = -ad, ad do
    local verif_code, verif_counter = totp_generate_password(self, d, for_time)
    if verif_counter >= self.counter and code == verif_code then
      self.counter = verif_counter + 1
      return true
    end
  end
  return false
end

function totpmt:get_url(raw_key, issuer, account, issuer_uuid)
  local key, issuer, account = url_encode((basexx.to_base32(raw_key):gsub('=', ''))), url_encode(issuer), url_encode(account)
  local issuer_uuid = issuer_uuid and url_encode(issuer_uuid) or issuer
  return table.concat{
    "otpauth://totp/",
    issuer, ":", account,
    "?secret=", key,
    "&issuer=", issuer_uuid,
    "&period=", tostring(self.period),
    "&digits=", tostring(self.digits),
    "&algorithm=", self.hash_alg,
  }
end

function totpmt:metadata()
  local fields = {
    "totp",
    metadata_format_version,
    tostring(self.digits),
    tostring(self.period),
    tostring(self.counter),
    self.hash_alg,
  }
  return table.concat(fields, ":") .. ":"
end

function totpmt:store_in_dsm(account, must_create)
  if account == nil or type(account) ~= "string" then
    return nil, Error.new("expected a string for `account`")
  end
  local name = totp_name_prefix .. account
  -- First see if the object exists
  local hmac_key, err = Sobject { name = name }
  if err == nil and must_create == true then
    return nil, Error.new("a security object associated with this account already exists")
  end
  local url = nil
  if err ~= nil then
    raw_key = Blob.random { bytes = self.key_length }:bytes()
    url = self:get_url(raw_key, totp_issuer, account)
    hmac_key, err = Sobject.import {
      name = name,
      value = Blob.from_bytes(raw_key),
      obj_type = 'HMAC',
      key_ops = {"HIGHVOLUME", "MACGENERATE"},
    }
    if err ~= nil then
      return nil, Error.new("failed to import HMAC key: " .. tostring(err))
    end
  end
  -- Update the custom metadata with TOTP parameters
  _, err = hmac_key:update { custom_metadata = { totp_params = self:metadata() } }
  if err ~= nil then return nil, err end
  return {
    security_object = name,
    url = url, -- will only have a value if a key was created.
  }
end

function otp.get_totp_from_dsm(account)
  local name = totp_name_prefix .. account
  local hmac_key, err = Sobject { name = name }
  if err ~= nil then return nil, Error.new("could not find the security object associated with this account: " .. tostring(err)) end
  if hmac_key.obj_type ~= "HMAC" then
    return nil, Error.new("expected an HMAC key found `" .. hmac_key.obj_type .. "`")
  end
  if (not hmac_key.custom_metadata) or (not hmac_key.custom_metadata.totp_params) then
    return nil, Error.new("could not find custom metadata `totp_params` on the key")
  end

  local totp_params = hmac_key.custom_metadata.totp_params
  local items = {}
  for item in string.gmatch(totp_params, "([^:]*):") do
    items[#items + 1] = item
  end
  if #items < 6 or items[1] ~= "totp" or tonumber(items[2]) > metadata_format_version then
    return nil, Error.new("invalid custom metadata value for `totp_params`")
  end
  local version = tonumber(items[2])
  if version == 1 then
    local r = {
      type = "totp",
      key_name = name,
      key_length = hmac_key.key_size / 8,
      digits = tonumber(items[3]),
      period = tonumber(items[4]),
      counter = tonumber(items[5] or "0"),
      hash_alg = items[6],
    }
    setmetatable(r, { __index = totpmt })
    return r
  else
    return nil, Error.new("unsupported serialization format version")
  end
end

-------------------------------------------------------------

function table_foreach(tab, func)
  local res = {}
  for k, v in pairs(tab) do
    res[k] = func(k, v)
  end
  return res
end

function expect_input_field(obj, field_name, expected_type, expected_json_type)
  if not obj[field_name] then
    return nil, Error.new("missing required input field `" .. field_name .. "`")
  end
  if type(obj[field_name]) ~= expected_type then
    return nil, Error.new("invalid value for `" .. field_name .. "`, expected a " .. (expected_json_type or expected_type))
  end
  return obj[field_name]
end


-- character table string
local b='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

-- encoding
function enc(data)
    return ((data:gsub('.', function(x)
        local r,b='',x:byte()
        for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
        return r;
    end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if (#x < 6) then return '' end
        local c=0
        for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
        return b:sub(c+1,c+1)
    end)..({ '', '==', '=' })[#data%3+1])
end

----------------- Constant --------------------
local PRIVATE_WALLET_VERSION =  "0488ADE4"
local FIRST_HARDENED_CHILD = 0x80000000

-- The order of the secp256k1 curve
local N = BigNum.from_bytes_be(Blob.from_hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141"))

------------- BIP32 key structure -------------
local key = {
   ["version"]="",     -- 4 byte version
   ["depth"]="",       -- 1 byte
   ["index"]="",       -- 4 byte child number
   ["fingerprint"]="", -- 4 byte parent fingerprint
   ["chain_code"]="",  -- 32 byte
   ["key"]="",         -- 33 byte long key
   ["checksum"]=""    -- checksum of all above
}


function ecdsa_sign(private_key, input)
   -- Assumed to be previously zero-padded if needed
   assert(#private_key == 32)

   local asn1_ec_key = Blob.from_hex("302E0201010420").. private_key .. Blob.from_hex("A00706052B8104000A")
   local subkey = assert(Sobject.import { name = "bip32 ec", obj_type = "EC", elliptic_curve = "SecP256K1", value = asn1_ec_key, transient = true })
   return assert(subkey:sign { hash = input, hash_alg = "SHA256", deterministic_signature = true }).signature
end


-- deserialize bip32 key
function deserialize(exported_master_key_serialized)
   local blob_key = Blob.from_base58(exported_master_key_serialized)

   if #blob_key ~= 82 then
      error("Unexpected key length" .. #blob_key)
   end

   key.version = blob_key:slice(1, 4)
   key.depth = blob_key:slice(5, 5)
   key.index = blob_key:slice(6, 9)
   key.fingerprint = blob_key:slice(10, 13)
   key.chain_code = blob_key:slice(14, 45)
   key.key = blob_key:slice(46, 78)
   key.checksum = blob_key:slice(79, 82)

   if key.version:hex() ~= PRIVATE_WALLET_VERSION then
      error("Unexpected key version")
   end

   return key
end

function format_rs(signature)
   local signature_length = tonumber(string.sub(signature, 3, 4), 16) + 2
   local r_length = tonumber(string.sub(signature, 7, 8), 16)
   local r_left = 9
   local r_right = r_length*2 + r_left - 1
   local r = BigNum.from_bytes_be(Blob.from_hex(string.sub(signature, r_left, r_right)))

   local s_left = r_right + 5
   local s_right = signature_length*2
   local s_length = tonumber(string.sub(signature, s_left-2, s_left-1), 16)
   local s = BigNum.from_bytes_be(Blob.from_hex(string.sub(signature, s_left, s_right)))

   local N_minus_s = N - s

   if s > N_minus_s then
      s = N_minus_s
   end

   return {
      r = r,
      s = s
   }
end

-- derive new child key from parent key
function derive_new_child(parent_key, child_idx)
   local index_hex = num2hex(child_idx, 8)

   local input

   if parent_key.version:hex() == PRIVATE_WALLET_VERSION and tonumber(child_idx) < FIRST_HARDENED_CHILD then
      -- parent is private
      -- input equal to public key of parent private
      input = compute_public_point(parent_key.key:slice(2, 33))
   else
      input = parent_key.key
   end

   input = input .. Blob.from_hex(index_hex)

   local hmac_key = assert(Sobject.import { name = "BIP32 mac", obj_type = "HMAC", value = parent_key.chain_code, transient = true })
   local hmac = assert(hmac_key:mac { data = input, alg = 'SHA512'}).digest

   fingerprint = hash160(compute_public_point(parent_key.key:slice(2,33)))

   child_key = {
      index = Blob.from_hex(index_hex),
      chain_code = hmac:slice(33, 64),
      depth = Blob.from_hex(num2hex(tonumber(parent_key.depth:hex()) + 1, 2)),
      version = parent_key.version,
      fingerprint = fingerprint:slice(1, 4),
      -- prefixing 00 to make key size 33 bytes
      key = Blob.from_hex("00") .. add_scalar(hmac:slice(1, 32), parent_key.key)
   }

   local child_key_blob = child_key.version .. child_key.depth .. child_key.fingerprint .. child_key.index .. child_key.chain_code .. child_key.key
   child_key.checksum = sha256d(child_key_blob):slice(1, 4)

   return child_key
end

-- convert number into hex string
function num2hex(num, size)
   return BigNum.from_int(num):to_bytes_be_zero_pad(size/2):hex()
end


function maybe_hard(path)
   if string.sub(path, -1) == 'H' then
      return tostring(tonumber(string.sub(path, 0, #path - 1)) + FIRST_HARDENED_CHILD)
   else
      return tostring(tonumber(path))
   end
end

-- return public key from private key
function compute_public_point(key_blob)
   local secp256k1 = EcGroup.from_name('SecP256K1')
   local secret_scalar = BigNum.from_bytes_be(key_blob)
   local public_point = secp256k1:generator():mul(secret_scalar)
   return public_point:to_binary()
end

-- return RIPEMD(SHA-256(data))
function hash160(data_blob)
   local sha256_hash = assert(digest { data = data_blob, alg = 'SHA256' }).digest
   local ripmd160_hash = assert(digest { data = sha256_hash, alg = 'RIPEMD160' }).digest
   return ripmd160_hash
end

-- Return SHA-256(SHA-256(data))
function sha256d(data_blob)
   local sha256_hash1 = assert(digest { data = data_blob, alg = 'SHA256' }).digest
   local sha256_hash2 = assert(digest { data = sha256_hash1, alg = 'SHA256' }).digest
   return sha256_hash2
end

-- add two secret scalar values
function add_scalar(k1, k2)
   local a = BigNum.from_bytes_be(k1)
   local b = BigNum.from_bytes_be(k2)
   a:add(b)
   a:mod(N)
   return a:to_bytes_be_zero_pad(32)
end

-- parse input path
function parse_path(path)
   local t = {}
   local fpat = "(.-)" .. "/"
   local last_end = 1
   local s, e, cap = path:find(fpat, 1)
   while s do
      if s ~= 1 or cap ~= "" then
         table.insert(t, maybe_hard(cap))
      end
      last_end = e+1
      s, e, cap = path:find(fpat, last_end)
   end
   if last_end <= #path then
      cap = path:sub(last_end)
      table.insert(t, maybe_hard(cap))
   end
   return t
end

function get_path(wallet_name, key_index)
   local sha256_hash = assert(digest { data = enc(wallet_name), alg = 'SHA256' }).digest
   local sha256_hash_a = string.sub(sha256_hash:hex(), 0, 8)
   local sha256_hash_b = string.sub(sha256_hash:hex(), 9, 16)
   local sha256_hash_c = string.sub(sha256_hash:hex(), 17, 24)
   local sha256_hash_d = string.sub(sha256_hash:hex(), 25, 32)
   local sha256_hash_e = string.sub(sha256_hash:hex(), 33, 40)
   local sha256_hash_f = string.sub(sha256_hash:hex(), 41, 48)
   local sha256_hash_g = string.sub(sha256_hash:hex(), 49, 56)
   local sha256_hash_h = string.sub(sha256_hash:hex(), 57, 64)
   local path_a = tonumber(sha256_hash_a, 16)
   local path_b = tonumber(sha256_hash_b, 16)
   local path_c = tonumber(sha256_hash_c, 16)
   local path_d = tonumber(sha256_hash_d, 16)
   local path_e = tonumber(sha256_hash_e, 16)
   local path_f = tonumber(sha256_hash_f, 16)
   local path_g = tonumber(sha256_hash_g, 16)
   local path_h = tonumber(sha256_hash_h, 16)
   local path = "m/" .. path_a .. "/" .. path_b .. "/" .. path_c .. "/" .. path_d .. "/" .. path_e .. "/" .. path_f .. "/" .. path_g .. "/" .. path_h .. "/" .. key_index
   return path
end


function get_pub_key(wallet_name, key_index)
   local path = get_path(wallet_name, key_index)
   local indices = parse_path(path)
   local master_key_obj = assert(Sobject {name = MASTER_KEY}, "master key not found")
   local master_key_bytes = assert(master_key_obj:export(), "master key not exportable")
   local master_key = deserialize(master_key_bytes.value:bytes())
   for i = 2, #indices do
      child_key = derive_new_child(master_key, tonumber(indices[i]))
      master_key = child_key
   end
   return {
       xpub = compute_public_point(child_key.key):hex():lower()
   }
end


function sign_eth(wallet_name, key_index, msg_hash)

   local path = get_path(wallet_name, key_index)
   local indices = parse_path(path)
   local master_key_obj = assert(Sobject {name = MASTER_KEY}, "master key not found")
   local master_key_bytes = assert(master_key_obj:export(), "master key not exportable")

   local master_key = deserialize(master_key_bytes.value:bytes())

   for i = 2, #indices do
      child_key = derive_new_child(master_key, tonumber(indices[i]))
      master_key = child_key
   end

   local signature = ecdsa_sign(child_key.key:slice(2, 33), Blob.from_hex(msg_hash)):hex()

   local rs = format_rs(signature)

   return {
      	r = rs.r:to_bytes_be_zero_pad(32):hex():lower(),
      	s = rs.s:to_bytes_be_zero_pad(32):hex():lower(),
    	xpub = compute_public_point(child_key.key):hex():lower()
   }

end


function run(input)

  local operation, err = expect_input_field(input, "operation", "string")
  if err ~= nil then return nil, err end

  local wallet_name, err = expect_input_field(input, "walletName", "string")
  if err ~= nil then return nil, err end

  local op_register = "register"
  local op_sign = "sign"
  local op_get_pub_key = "getPubKey"

  local all_ops = { op_generate, op_sign, op_get_pub_key }

  if operation == op_register then
    local totp = otp.new_totp(wallet_name)
    return totp:store_in_dsm(wallet_name, true) -- must_create
  end

  if operation == op_get_pub_key then
    local key_index, err = expect_input_field(input, "keyIndex", "string")
  	if err ~= nil then return nil, err end

	return get_pub_key(wallet_name, key_index)
  end

  if operation == op_sign then

    local key_index, err = expect_input_field(input, "keyIndex", "string")
  	if err ~= nil then return nil, err end

    local msg_hash, err = expect_input_field(input, "msgHash", "string")
  	if err ~= nil then return nil, err end

    local totp, err = otp.get_totp_from_dsm(wallet_name)

    if err ~= nil then
      return sign_eth(wallet_name, key_index, msg_hash)
    end

    local code, err = expect_input_field(input, "code", "string")
    if err ~= nil then return nil, err end

    if err ~= nil then return nil, err end
    local verified = totp:verify(code)
    totp:store_in_dsm(wallet_name, false) -- to ensure the same code cannot be used again

    if verified == true then
    	return sign_eth(wallet_name, key_index, msg_hash)
    else
      	return nil, Error.new("TOTP not verified")
    end
  end

  local all_ops_quoted = table_foreach(all_ops, function(k, v) return "'" .. v .. "'" end)
  return nil, Error.new("unknown operation '" .. operation .. "', expected one of the following: " .. table.concat(all_ops_quoted, ", "))
end