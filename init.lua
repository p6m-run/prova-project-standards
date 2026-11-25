-- prova-project-standards — the p6m project standards, as proofs.
--
-- A standard nobody can run is a wiki page. This package turns each one into a `prova.test`, so
-- `prova` and CI enforce it with no new tooling, a violation reads like any other failure, and a
-- deliberate exception is a WAIVER WITH A REASON committed to the repo instead of silence.
--
-- A project adopts it with one proof file:
--
--   -- proofs/standards.prova.lua
--   require("project-standards").check {}
--
-- ## Profiles
--
-- Not every standard applies to every project, so each rule carries a PROFILE, and a project runs
-- the profiles it matches. `standards.profiles(root)` detects them from what is on disk;
-- `profiles = {...}` ADDS to what is detected (it never drops one).
--
--   repo          every repository: a README, a .gitignore
--   prova-suite   anything with a prova manifest, or a Cargo.toml (which should have one):
--                 the manifest, its prova floor, no retired surface, proof naming, pinned
--                 dependencies, a CI profile that states what the runner guarantees
--   cargo         any Cargo project: edition, resolver, target/ ignored, the quality legs and
--                 their committed floor, clippy gated at -D warnings, no blanket allows,
--                 formatted
--
-- The bar is calibrated to `prova init rust-project`: a fresh retrofit passes every rule except
-- `cargo/quality-baseline`, which goes green after the first-run ritual
-- (`prova run quality --update-baseline`, then commit the baseline).
--
-- ## Waivers
--
-- `except` skips a rule WITH A REASON, reported as a skip rather than vanishing — visible debt, not
-- a silent exemption:
--
--   except = {
--     ["cargo/formatted"] = { why = "one-time reformat lands with YP6M-1234", owner = "jdoe", ends = "2026-12-31" },
--     ["cargo/edition"]   = "pinned to 2021 until the FFI crate drops its requirement",
--   }
--
-- A waiver whose `ends` has passed turns red again, so debt is dated rather than permanent.
--
-- ## Adding a standard
--
-- Append a `rule{}` below and a falsifying case to proofs/. `id` is the waiver key and never
-- changes once projects depend on it; `why` is the sentence a person reads when it fails, so write
-- the REASON, not a restatement of the title.

local path = prova.path

local standards = {}

--- The org's bar, as data. Raise a floor here, release, move `v1`: every adopting project is told on
--- its next run.
standards.defaults = {
	-- The oldest prova a project's suite may declare it needs. The ratchet that stops the org
	-- spreading across prova generations while every manifest still looks current.
	prova_floor = "0.30",
	-- The oldest Rust edition a crate may be on. p6m runs both 2021 and 2024 today, so this is a
	-- floor, not an exact value: what it catches is a crate with NO edition, which cargo reads as 2015.
	edition_floor = "2021",
	-- Feature resolvers a workspace may pin. "1" is what cargo silently uses in a virtual workspace
	-- that names none.
	resolvers = { "2", "3" },
	-- The profiles `prova init rust-project` renders, which every Cargo project must keep declared.
	quality_legs = { "quality", "ut", "all" },
	-- Where the quality ratchet keeps its committed floor.
	baseline = ".prova/baselines/quality.json",
	-- Lints that must never be switched off wholesale.
	blanket_allows = { "warnings", "unused", "clippy::all", "clippy::correctness", "clippy::suspicious" },
}

-- ── Reading the project ─────────────────────────────────────────────────────────────────────────

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function read_or_nil(p)
	if not fs.exists(p) then
		return nil
	end
	local ok, s = pcall(fs.read, p)
	return ok and s or nil
end

local function decode_toml(text)
	if not text then
		return nil
	end
	local ok, decoded = pcall(toml.decode, text)
	return ok and decoded or nil
end

--- A literal string, safe to splice into a Lua pattern (`-` is a quantifier there, not a hyphen).
local function literal(s)
	return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

local function rel(root, p)
	return (p:gsub("^" .. literal(root) .. "/?", ""))
end

--- Build output and vendored trees no rule judges.
local NOT_SOURCE = { "/target/", "/.git/", "/.jj/", "/node_modules/", "/vendor/", "/.prova/var/" }

local function is_source(relpath)
	for _, fragment in ipairs(NOT_SOURCE) do
		if ("/" .. relpath):find(fragment, 1, true) then
			return false
		end
	end
	return true
end

--- `a < b`, comparing dotted numeric versions component-wise ("0.30" equals "0.30.0").
local function version_lt(a, b)
	local function parts(v)
		local out = {}
		for n in tostring(v):gmatch("%d+") do
			out[#out + 1] = tonumber(n)
		end
		return out
	end
	local pa, pb = parts(a), parts(b)
	for i = 1, math.max(#pa, #pb) do
		local x, y = pa[i] or 0, pb[i] or 0
		if x ~= y then
			return x < y
		end
	end
	return false
end
standards.version_lt = version_lt

--- The four places prova accepts a manifest, in discovery's order.
local MANIFEST_LOCATIONS = { "prova.toml", ".prova.toml", "prova/prova.toml", ".prova/prova.toml" }

local function find_manifest(root)
	for _, r in ipairs(MANIFEST_LOCATIONS) do
		local p = path.join(root, r)
		if fs.exists(p) then
			return r, decode_toml(read_or_nil(p))
		end
	end
	return nil, nil
end

--- Every crate manifest in the project: the root's own `[package]`, plus each workspace member
--- (globs expanded). `{ rel, toml }` per crate, sorted.
local function crate_manifests(root, cargo)
	local out, seen = {}, {}
	local function add(p)
		if not seen[p] then
			seen[p] = true
			local m = decode_toml(read_or_nil(p))
			if m and m.package then
				out[#out + 1] = { rel = rel(root, p), toml = m }
			end
		end
	end
	if cargo and cargo.package then
		add(path.join(root, "Cargo.toml"))
	end
	local ws = cargo and cargo.workspace
	for _, member in ipairs(ws and ws.members or {}) do
		for _, p in ipairs(fs.glob(root, member .. "/Cargo.toml")) do
			add(p)
		end
	end
	table.sort(out, function(a, b)
		return a.rel < b.rel
	end)
	return out
end

--- Everything the rules read, gathered once per check.
---@param root string|nil
function standards.project(root)
	root = path.normalize(root or prova.root)
	local cargo = decode_toml(read_or_nil(path.join(root, "Cargo.toml")))
	local manifest_rel, manifest = find_manifest(root)
	return {
		root = root,
		cargo = cargo,
		crates = crate_manifests(root, cargo),
		manifest_rel = manifest_rel,
		manifest = manifest,
		gitignore = read_or_nil(path.join(root, ".gitignore")),
	}
end

--- The directories the manifest names as proof directories.
local function proof_dirs(project)
	local run = project.manifest and project.manifest.run or {}
	local dirs = run.proofs
	return type(dirs) == "table" and dirs or { "proofs" }
end

--- Proof-directory files matching `suffix`, project-relative and sorted. Bounded to
--- `<dir>/`, `*/<dir>/` and `*/*/<dir>/` rather than any depth: an unbounded walk crosses
--- `target/` and costs seconds on a real workspace.
local function proof_files(project, suffix)
	local found, seen = {}, {}
	for _, dir in ipairs(proof_dirs(project)) do
		local patterns = dir == "." and { "*" .. suffix }
			or { dir .. "/**/*" .. suffix, "*/" .. dir .. "/**/*" .. suffix, "*/*/" .. dir .. "/**/*" .. suffix }
		for _, pattern in ipairs(patterns) do
			for _, p in ipairs(fs.glob(project.root, pattern)) do
				local r = rel(project.root, p)
				if is_source(r) and not seen[r] then
					seen[r] = true
					found[#found + 1] = r
				end
			end
		end
	end
	table.sort(found)
	return found
end

--- Proof files still on a spelling prova accepts quietly: `*_test.lua`, `*.test.lua`.
function standards.legacy_proof_files(project)
	local out = {}
	for _, suffix in ipairs({ "_test.lua", ".test.lua" }) do
		for _, f in ipairs(proof_files(project, suffix)) do
			out[#out + 1] = f
		end
	end
	table.sort(out)
	return out
end

--- Git dependencies in the manifest that are not pinned to a tag: `{ name, how }`, sorted.
function standards.unpinned_dependencies(manifest)
	local out = {}
	for name, dep in pairs(manifest and manifest.dependencies or {}) do
		if type(dep) == "table" and type(dep.git) == "string" and type(dep.tag) ~= "string" then
			local how = dep.rev and ("rev " .. tostring(dep.rev))
				or dep.branch and ("branch " .. tostring(dep.branch))
				or "no tag, rev or branch: the default branch, wherever it is today"
			out[#out + 1] = { name = name, how = how }
		end
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

--- Crates below the edition floor, or with no edition at all (which cargo reads as 2015).
function standards.edition_findings(project, floor)
	local ws_pkg = project.cargo and project.cargo.workspace and project.cargo.workspace.package or {}
	local out = {}
	for _, crate in ipairs(project.crates) do
		local e = crate.toml.package.edition
		if type(e) == "table" and e.workspace then
			e = ws_pkg.edition
		end
		if e == nil then
			out[#out + 1] = crate.rel .. ": no edition, which cargo reads as 2015"
		elseif version_lt(tostring(e), floor) then
			out[#out + 1] = ("%s: edition %s"):format(crate.rel, tostring(e))
		end
	end
	return out
end

--- `#![allow(...)]` / `#[allow(...)]` attributes that switch off a whole lint group, in Rust source
--- outside build output: `"<file>:<line>: <attribute>"`, sorted.
function standards.blanket_allows(root, lints)
	local banned = {}
	for _, l in ipairs(lints) do
		banned[l] = true
	end
	local out = {}
	for _, p in ipairs(fs.glob(root, "**/*.rs")) do
		local r = rel(root, p)
		if is_source(r) then
			local n = 0
			for line in ((read_or_nil(p) or "") .. "\n"):gmatch("(.-)\n") do
				n = n + 1
				local inner = line:match("^%s*#!?%[%s*allow%s*%((.-)%)%s*%]")
				if inner then
					for lint in inner:gmatch("[%w_:]+") do
						if banned[lint] then
							out[#out + 1] = ("%s:%d: %s"):format(r, n, trim(line))
							break
						end
					end
				end
			end
		end
	end
	table.sort(out)
	return out
end

--- Whether a proof in the quality leg runs clippy and denies warnings, judged on code with
--- comments and whitespace removed.
function standards.clippy_gated(project)
	for _, f in ipairs(proof_files(project, ".lua")) do
		local code = {}
		for line in ((read_or_nil(path.join(project.root, f)) or "") .. "\n"):gmatch("(.-)\n") do
			if not line:match("^%s*%-%-") then
				code[#code + 1] = line
			end
		end
		local flat = table.concat(code, "\n"):gsub("%s+", "")
		if flat:find('"cargo","clippy"', 1, true) and flat:find('"-D","warnings"', 1, true) then
			return true, f
		end
	end
	return false
end

-- ── The rules ───────────────────────────────────────────────────────────────────────────────────

local RULES = {}

local function rule(spec)
	RULES[#RULES + 1] = spec
end

local function no_manifest(t)
	return t:skip("no prova manifest yet — see prova-suite/manifest")
end

-- Profile: repo

rule({
	id = "repo/readme",
	profile = "repo",
	title = "the repository carries a non-empty README.md",
	why = "the first question about any repository is what it is, and the answer belongs where every tool already looks",
	check = function(t, c)
		local p = path.join(c.project.root, "README.md")
		t:expect(p, "README.md at the project root"):is_file()
		t:expect(#trim(read_or_nil(p) or ""), "and it says something"):gt(0)
	end,
})

rule({
	id = "repo/gitignore",
	profile = "repo",
	title = "the repository carries a .gitignore",
	why = "without one the first careless add commits build output, and removing it later does not remove it from history",
	check = function(t, c)
		t:expect(path.join(c.project.root, ".gitignore"), ".gitignore at the project root"):is_file()
	end,
})

-- Profile: prova-suite — how the project is VERIFIED. `prova init rust-project` renders this surface
-- once; these rules keep it wired.

rule({
	id = "prova-suite/manifest",
	profile = "prova-suite",
	title = "the project has a prova manifest",
	why = "a project with no manifest has no runnable answer to `is this broken`, so the answer is whatever the last person to touch it remembers",
	check = function(t, c)
		t:expect(
			c.project.manifest_rel ~= nil,
			"a prova manifest (prova.toml, .prova.toml, prova/ or .prova/) — `prova init rust-project` renders one"
		):is_true()
	end,
})

rule({
	id = "prova-suite/requires-floor",
	profile = "prova-suite",
	title = "the suite declares the prova it needs, at or above the org floor",
	why = "an undeclared floor fails mid-run on a feature the binary lacks; a stale one lets a project sit a generation behind while its manifest still looks current",
	check = function(t, c)
		local m = c.project.manifest
		if not m then
			return no_manifest(t)
		end
		local spec = m.requires and m.requires.prova
		t:expect(type(spec) == "string" and spec or nil, "[requires] prova"):never():is_nil()
		-- A semver RANGE: a bare "0.30" means `^0.30` and refuses 0.31, the opposite of a floor.
		local floor = spec:match(">=%s*([%d%.]+)")
		t:expect(floor, "spelled as a floor (`>= x.y`); a bare version is `^x.y` and refuses the next minor"):never():is_nil()
		t:expect(
			not version_lt(floor, c.cfg.prova_floor),
			("at or above the org floor of %s (this suite declares %s)"):format(c.cfg.prova_floor, floor)
		):is_true()
	end,
})

rule({
	id = "prova-suite/no-retired-surface",
	profile = "prova-suite",
	title = "the manifest uses no retired prova surface",
	why = "prova warns about every retired key on every run, and a warning nobody reads is a manifest that stops loading at 1.0. Delegated to the binary on purpose: prova is the authority on what it has retired, so this rule never goes stale",
	check = function(t, c)
		if not c.project.manifest then
			return no_manifest(t)
		end
		local probe = t:use(c.fixtures.manifest)
		t:expect(probe.code, "`prova run --list` succeeded — " .. probe.output):equals(0)
		t:expect(#probe.deprecations, "prova reported retired surface:\n  " .. table.concat(probe.deprecations, "\n  "))
			:equals(0)
	end,
})

rule({
	id = "prova-suite/proof-naming",
	profile = "prova-suite",
	title = "proof files are named `*.prova.lua`",
	why = "prova still accepts `*_test.lua` and `*.test.lua` QUIETLY, which is how a convention rots; the name is what tells a reader a file is a black-box proof and not a unit test",
	check = function(t, c)
		if not c.project.manifest then
			return no_manifest(t)
		end
		local legacy = standards.legacy_proof_files(c.project)
		t:expect(#legacy, ("rename to `*.prova.lua`:\n  %s"):format(table.concat(legacy, "\n  "))):equals(0)
	end,
})

rule({
	id = "prova-suite/dependencies-pinned",
	profile = "prova-suite",
	title = "git dependencies are pinned to a released tag",
	why = "a rev never receives the fix and a branch receives one nobody asked for. A floating major tag (`v1`) is how a new standard reaches every project on its next resolve, while a breaking change stays a deliberate move to `v2`",
	check = function(t, c)
		local m = c.project.manifest
		if not m then
			return no_manifest(t)
		end
		local found = standards.unpinned_dependencies(m)
		local lines = {}
		for _, f in ipairs(found) do
			lines[#lines + 1] = f.name .. " (" .. f.how .. ")"
		end
		t:expect(#found, "pin each to a tag:\n  " .. table.concat(lines, "\n  ")):equals(0)
	end,
})

rule({
	id = "prova-suite/ci-profile",
	profile = "prova-suite",
	title = "the suite has a CI profile that states what the runner guarantees",
	why = "`must_run` is the inverse of a test's `requires`: without it a runner that lost a tool skips every proof that needed it and still exits 0, so `we answered everything` reads the same as `we could not ask anything`",
	check = function(t, c)
		local m = c.project.manifest
		if not m then
			return no_manifest(t)
		end
		local ci = m.profiles and m.profiles.ci
		t:expect(ci ~= nil, "[profiles.ci] is declared"):is_true()
		-- Declared, not non-empty: `must_run = []` is the honest answer for a hermetic suite.
		t:expect(type(ci.must_run) == "table", "and it declares must_run, even if empty"):is_true()
	end,
})

-- Profile: cargo — any Cargo project, binary or library.

rule({
	id = "cargo/edition",
	profile = "cargo",
	title = "every crate is on a current Rust edition",
	why = "a crate with no `edition` is compiled as Rust 2015, silently; one edition floor means code moves between projects without a migration first",
	check = function(t, c)
		t:expect(#c.project.crates > 0, "Cargo.toml declares a [package] or workspace members"):is_true()
		local found = standards.edition_findings(c.project, c.cfg.edition_floor)
		t:expect(#found, ("below the %s floor:\n  %s"):format(c.cfg.edition_floor, table.concat(found, "\n  "))):equals(0)
	end,
})

rule({
	id = "cargo/resolver",
	profile = "cargo",
	title = "a virtual workspace pins its feature resolver",
	why = "a workspace with no root [package] does not inherit an edition's resolver: it gets resolver 1, so features differ from what each crate built alone",
	check = function(t, c)
		local cargo = c.project.cargo
		local ws = cargo and cargo.workspace
		if not ws or cargo.package then
			return t:skip("not a virtual workspace: the root package's edition implies the resolver")
		end
		local ok = false
		for _, r in ipairs(c.cfg.resolvers) do
			ok = ok or tostring(ws.resolver) == r
		end
		t:expect(ok, ("[workspace] resolver is one of %s (it is %s)"):format(
			table.concat(c.cfg.resolvers, ", "), tostring(ws.resolver))):is_true()
	end,
})

rule({
	id = "cargo/ignores-target",
	profile = "cargo",
	title = "the build directory is ignored",
	why = "`target/` is gigabytes of regenerable output; committing one file from it is easy and undoing it is a history rewrite",
	check = function(t, c)
		t:expect(c.project.gitignore or "", ".gitignore covers target/"):matches("target")
	end,
})

rule({
	id = "cargo/quality-legs",
	profile = "cargo",
	title = "the suite declares the standard quality legs",
	why = "one bar across the org means `prova run quality` means the same thing in every repository; `prova init rust-project` renders these legs",
	check = function(t, c)
		local m = c.project.manifest
		if not m then
			return no_manifest(t)
		end
		local profiles = m.profiles or {}
		t:expect_all(function()
			for _, leg in ipairs(c.cfg.quality_legs) do
				t:expect(profiles[leg] ~= nil, ("[profiles.%s] is declared"):format(leg)):is_true()
			end
		end)
	end,
})

rule({
	id = "cargo/clippy-gated",
	profile = "cargo",
	title = "a proof holds clippy to -D warnings",
	why = "a warning that only prints is a warning nobody fixes: the wall holds only when a proof fails on one. `prova init rust-project` renders proofs/quality/clippy.prova.lua",
	check = function(t, c)
		if not c.project.manifest then
			return no_manifest(t)
		end
		local gated = standards.clippy_gated(c.project)
		t:expect(gated, "a proof runs `cargo clippy ... -- -D warnings`"):is_true()
	end,
})

rule({
	id = "cargo/no-blanket-allows",
	profile = "cargo",
	title = "no attribute switches off a whole lint group",
	why = "`#![allow(warnings)]` and friends make the clippy wall pass by not looking; allow the one lint, at the one item, with a comment saying why",
	check = function(t, c)
		local found = standards.blanket_allows(c.project.root, c.cfg.blanket_allows)
		t:expect(#found, "narrow each to the specific lint:\n  " .. table.concat(found, "\n  ")):equals(0)
	end,
})

rule({
	id = "cargo/quality-baseline",
	profile = "cargo",
	title = "the quality ratchet has a committed floor",
	why = "the ratchet refuses to pass without one, so a missing baseline is a leg that has never gated anything: run `prova run quality --update-baseline` once and commit what it writes",
	check = function(t, c)
		if not c.project.manifest then
			return no_manifest(t)
		end
		t:expect(path.join(c.project.root, c.cfg.baseline), c.cfg.baseline):is_file()
	end,
})

rule({
	id = "cargo/formatted",
	profile = "cargo",
	title = "the workspace is formatted (cargo fmt --check)",
	why = "unchecked formatting drifts until one `cargo fmt` rewrites files nobody touched, and the real change hides in that diff",
	requires = { "cargo" },
	compiles = true,
	check = function(t, c)
		local r = shell.run({ "cargo", "fmt", "--all", "--check" }, { cwd = c.project.root, merge_stderr = true, timeout = "120s" })
		t:expect(r.code, "run `cargo fmt --all`:\n" .. (r.stdout or "")):equals(0)
	end,
})

-- ── Selecting and running ──────────────────────────────────────────────────────────────────────

--- The profiles a project matches, from what is on disk.
function standards.profiles(root)
	root = root or prova.root
	local found = { "repo" }
	local has_cargo = fs.exists(path.join(root, "Cargo.toml"))
	if has_cargo then
		found[#found + 1] = "cargo"
	end
	-- A Cargo project SHOULD have a suite: `prova init rust-project` retrofits one in a command.
	if has_cargo or find_manifest(root) then
		found[#found + 1] = "prova-suite"
	end
	return found
end

--- Every rule, or those in the given profiles, in declaration (= reporting) order.
---@param profiles string[]|nil
function standards.rules(profiles)
	if not profiles then
		return RULES
	end
	local want = {}
	for _, p in ipairs(profiles) do
		want[p] = true
	end
	local out = {}
	for _, r in ipairs(RULES) do
		if want[r.profile] then
			out[#out + 1] = r
		end
	end
	return out
end

--- What a waiver says on `today` (YYYY-MM-DD): `"expired"` once its `ends` has passed or is not a
--- date, else `"waived"`. A waiver is a reason string or `{ why, owner?, ends? }`.
---@return string verdict, string text
function standards.waiver(w, today)
	if type(w) == "table" then
		local owner = w.owner and (" (" .. w.owner .. ")") or ""
		if w.ends ~= nil then
			if type(w.ends) ~= "string" or not w.ends:match("^%d%d%d%d%-%d%d%-%d%d$") then
				return "expired", ("waiver%s has an end that is not a YYYY-MM-DD date: %s"):format(owner, tostring(w.ends))
			end
			if w.ends < today then
				return "expired", ("waiver%s ended %s — fix it, or renew with a new end: %s"):format(owner, w.ends, w.why or "no reason given")
			end
			return "waived", ("waived until %s%s: %s"):format(w.ends, owner, w.why or "no reason given")
		end
		return "waived", ("waived%s: %s"):format(owner, w.why or "no reason given")
	end
	if type(w) == "string" then
		return "waived", "waived: " .. w
	end
	return "waived", "waived without a reason — say why in `except`"
end

--- The keys a project's own suite may pass. Anything else (the floors, the lint list) is the
--- standards' own, so a repository cannot lower its own bar from inside the check.
standards.REPO_OPTS = { root = true, label = true, except = true, profiles = true, today = true }

--- Hold the project to the standards: one test per applicable rule. Call from a proof file.
---@param opts table|nil
function standards.check(opts)
	opts = opts or {}
	local root = path.normalize(opts.root or prova.root)

	local refused = {}
	for k in pairs(opts) do
		if not standards.REPO_OPTS[k] then
			refused[#refused + 1] = tostring(k)
		end
	end
	table.sort(refused)

	local merged, seen = {}, {}
	for _, list in ipairs({ standards.profiles(root), opts.profiles or {} }) do
		for _, p in ipairs(list) do
			if not seen[p] then
				seen[p] = true
				merged[#merged + 1] = p
			end
		end
	end

	local waived = {}
	for k, v in pairs(opts.except or {}) do
		if type(k) == "number" then
			waived[v] = false
		else
			waived[k] = v
		end
	end

	local project = standards.project(root)
	local cfg = standards.defaults
	local today = opts.today or os.date("!%Y-%m-%d")

	-- What prova itself makes of the manifest. `run --list` parses and runs nothing, so it is
	-- milliseconds; `prova.bin` is the binary CONDUCTING this run, the one the project uses.
	local fixtures = {}
	fixtures.manifest = prova.fixture("project-standards:manifest:" .. root, Scope.File, function()
		local r = shell.run({ prova.bin, "run", "--list" }, { cwd = root, timeout = "120s", merge_stderr = true })
		local output = trim(r.stdout or "")
		local deprecations = {}
		for line in output:gmatch("[^\n]+") do
			if line:find("deprecated", 1, true) then
				deprecations[#deprecations + 1] = trim(line)
			end
		end
		return { code = r.code, output = output, deprecations = deprecations }
	end)

	prova.describe(opts.label or "project standards", function()
		if #refused > 0 then
			prova.test("the check takes only what describes the project", { tags = { "standards" } }, function(t)
				t:expect(false, "standards.check does not take: " .. table.concat(refused, ", ")
					.. " (it takes root, label, except, profiles)"):is_true()
			end)
		end
		for _, r in ipairs(standards.rules(merged)) do
			prova.test(r.title, {
				proves = r.id .. " — " .. r.why,
				tags = { "standards", r.profile, r.compiles and "compiles" or "static" },
				requires = r.requires,
			}, function(t)
				if waived[r.id] ~= nil then
					local verdict, text = standards.waiver(waived[r.id], today)
					if verdict == "expired" then
						t:expect(false, r.id .. ": " .. text):is_true()
						return
					end
					return t:skip(r.id .. " " .. text)
				end
				r.check(t, { project = project, cfg = cfg, fixtures = fixtures })
			end)
		end
	end)
end

return standards
