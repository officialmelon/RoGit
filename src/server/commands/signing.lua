--[[
Signed commits and tags with SSH (ed25519) keys:

  git signing-key generate [<comment>]   make a key (prints the public key to add to GitHub as a *signing* key)
  git signing-key import [<key>]         use an existing unencrypted OpenSSH ed25519 key (opens an editor when no key is given)
  git signing-key show | remove
  git commit -S / git tag -s / git config --global commit.gpgsign true
  git verify-commit <commit>, git verify-tag <tag>, git log --show-signature
]]
local HttpService = game:GetService("HttpService")

local arguments = require(script.Parent.Parent.arguments)
local Handlers = require(script.Parent.Parent.libs.git_handlers)
local repo = require(script.Parent.Parent.libs.repo)
local output = require(script.Parent.Parent.libs.output)
local hashlib = require(script.Parent.Parent.libs.hashlib)
local sshsig = require(script.Parent.Parent.libs.sshsig)
local ed25519 = require(script.Parent.Parent.libs.ed25519)
local Auth = require(script.Parent.Parent.libs.localstore)
local editor = require(script.Parent.Parent.libs.editor)

local function print(...)
    output.print(...)
end

local function plugin_settings()
    local plugin = Auth.ACTIVE_PLUGIN or _G.ACTIVE_PLUGIN
    if not plugin then
        error("fatal: signing keys are kept in the plugin settings, which need the plugin to be running", 0)
    end
    return plugin
end

--[[
32 random bytes. GUIDs come from the system's random generator; several are mixed through SHA-256 with other noise.
]]
local function random_seed()
    local parts = {}
    for _ = 1, 8 do
        table.insert(parts, HttpService:GenerateGUID(false))
    end
    local rng = Random.new()
    for _ = 1, 8 do
        table.insert(parts, tostring(rng:NextNumber()))
    end
    table.insert(parts, tostring(os.clock()) .. tostring(os.time()) .. tostring(tick and tick() or 0))
    return hashlib.hex_to_bin(hashlib.sha256(table.concat(parts, "|")))
end

local function show_key(seed)
    local email = Auth.getConfigValue("user_email") or "ro-git@example.com"
    print(sshsig.public_key_line(seed, email))
    print("")
    print("Key fingerprint: " .. sshsig.fingerprint(ed25519.public_key(seed)))
    print("Add the line above on GitHub: Settings > SSH and GPG keys > New SSH key > Key type: Signing Key.")
    print("Commits are shown as Verified when your commit email (git config --global user.email) belongs to that account.")
end

arguments.createArgument("git", "signing-key", "", function(...)
    local tuple = {...}
    local sub = tuple[1] or "show"

    if sub == "generate" then
        if repo.signing_seed() and tuple[2] ~= "--force" then
            error("error: a signing key already exists, use 'git signing-key generate --force' to replace it", 0)
        end
        local seed = random_seed()
        plugin_settings():SetSetting("user_signingkey_seed", hashlib.bin_to_base64(seed))
        print("Generated a new ed25519 signing key.\n")
        show_key(seed)
        print("\nSign every commit with: git config --global commit.gpgsign true")

    elseif sub == "import" then
        local text = tuple[2] and table.concat(tuple, " ", 2) or editor.edit(
            "-- Paste your OpenSSH private key below (the whole -----BEGIN OPENSSH PRIVATE KEY----- block),\n"
            .. "-- then close this script. The key must not have a passphrase.\n"
            .. "-- It is stored in your plugin settings, never inside the place.\n\n",
            "SIGNING_KEY"
        )
        local seed, reason = sshsig.parse_private_key(text or "")
        if not seed then
            error("error: " .. tostring(reason), 0)
        end
        plugin_settings():SetSetting("user_signingkey_seed", hashlib.bin_to_base64(seed))
        print("Imported signing key.\n")
        show_key(seed)

    elseif sub == "show" then
        local seed = repo.signing_seed()
        if not seed then
            error("No signing key yet. Create one with 'git signing-key generate'.", 0)
        end
        show_key(seed)

    elseif sub == "remove" then
        plugin_settings():SetSetting("user_signingkey_seed", nil)
        print("Signing key removed.")

    else
        error("usage: git signing-key (generate [--force] | import [<key>] | show | remove)", 0)
    end
end)

--[[
The text git prints for a verified signature.
]]
local function describe(sha)
    local status, fingerprint, reason = repo.verify_signature(sha)
    local own = repo.signing_seed()
    local own_fingerprint = own and sshsig.fingerprint(ed25519.public_key(own)) or nil
    if status == "G" then
        local who = (Handlers.read_commit(sha) or {}).committer
        local email = who and who:match("<(.-)>") or "?"
        local trust = fingerprint == own_fingerprint and "" or " (key is not yours; check it is on the signer's GitHub account)"
        return true, string.format('Good "git" signature for %s with ED25519 key %s%s', email, fingerprint, trust)
    elseif status == "B" then
        return false, string.format('BAD signature from key %s (%s)', tostring(fingerprint), tostring(reason))
    elseif status == "N" then
        return false, "no signature found"
    end
    return false, "Can't check signature: " .. tostring(reason)
end

local function verify_command(kind)
    return function(...)
        repo.require_root()
        local revs = {}
        for _, arg in ipairs({...}) do
            if arg:sub(1, 1) ~= "-" then table.insert(revs, arg) end
        end
        if #revs == 0 then
            error("usage: git verify-" .. kind .. " <" .. kind .. ">...", 0)
        end
        local all_good = true
        for _, rev in ipairs(revs) do
            local sha
            if kind == "tag" then
                sha = Handlers.get_ref("refs/tags/" .. rev)
            else
                sha = Handlers.resolve_revision(rev)
            end
            if not sha then
                error("error: " .. rev .. ": cannot verify a non-" .. kind .. " object", 0)
            end
            local good, text = describe(sha)
            print(text)
            all_good = all_good and good
        end
        if not all_good then
            error("", 0)
        end
    end
end

arguments.createArgument("git", "verify-commit", "", verify_command("commit"))
arguments.createArgument("git", "verify-tag", "", verify_command("tag"))

return {
    describe = describe,
}
