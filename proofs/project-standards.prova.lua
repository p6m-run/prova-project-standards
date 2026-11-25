-- Self-test for prova-project-standards. `require("project-standards")` resolves to THIS package
-- (prova.toml declares it as a path dependency at "."), so the suite proves it the way a consumer
-- uses it. Hermetic: synthetic projects in a tempdir, no network. Only `cargo/formatted` needs a
-- toolchain, and it says so with `requires`.
--
-- The discipline is falsifiability: every rule passes a compliant project and FAILS a project broken
-- in exactly one way. A rule that cannot fail is a comment with a green tick next to it.

local standards = require("project-standards")
local path = prova.path

-- ── A compliant project: what `prova init rust-project` renders, plus the first-run baseline ──────

local MANIFEST = [[
[run]
proofs = ["proofs"]

[profiles.quality]
proofs   = ["quality"]
switches = ["quality"]

[profiles.ut]
proofs   = ["ut"]
switches = ["ut"]
must_run = ["cargo-nextest"]

[profiles.all]
switches = ["ut", "quality"]
must_run = ["cargo-nextest"]

[profiles.ci]
must_run = ["cargo"]

[requires]
prova = ">= 0.30"
]]

local CLIPPY_PROOF = [[
prova.test("clippy is clean", { switch = "quality" }, function(t)
	local r = shell.run(
		{ "cargo", "clippy", "--workspace", "--all-targets", "--", "-D", "warnings" },
		{ cwd = prova.root, merge_stderr = true }
	)
	t:expect(r.code, r.stdout):equals(0)
end)
]]

local COMPLIANT = {
	["README.md"] = "# demo\n\nA demo crate.\n",
	[".gitignore"] = "/target\n",
	["Cargo.toml"] = '[package]\nname = "demo"\nversion = "0.1.0"\nedition = "2024"\n',
	["src/lib.rs"] = "pub fn answer() -> u32 {\n    42\n}\n",
	[".prova/prova.toml"] = MANIFEST,
	[".prova/baselines/quality.json"] = "{}\n",
	["proofs/quality/clippy.prova.lua"] = CLIPPY_PROOF,
	["proofs/smoke.prova.lua"] = 'prova.test("smoke", function(t) t:expect(1):equals(1) end)\n',
}

--- A synthetic project: the compliant tree with `edits` applied (a string replaces a file, false
--- removes it).
local function project(t, edits, name)
	local root = t:tempdir(name or "project")
	local files = {}
	for k, v in pairs(COMPLIANT) do
		files[k] = v
	end
	for k, v in pairs(edits or {}) do
		files[k] = v or nil
	end
	for rel, text in pairs(files) do
		local p = path.join(root, rel)
		fs.mkdir(path.dirname(p))
		fs.write(p, text)
	end
	return root
end

--- Runs one rule's check against a project with a recording stand-in for `t`, so a rule's failure
--- is observed rather than failing this test. Aborts at the first failed expectation, as the real
--- context does. Returns `{ failures = {...}, skipped = reason|nil }`.
local function judge(id, root, probe)
	local rec = { failures = {} }
	local ABORT = {}
	local function matcher(v, msg, negate)
		local m = {}
		local function check(ok, what)
			if negate then
				ok = not ok
			end
			if not ok then
				rec.failures[#rec.failures + 1] = tostring(msg) .. " [" .. what .. "]"
				error(ABORT)
			end
			return m
		end
		function m:never() return matcher(v, msg, not negate) end
		function m:equals(x) return check(v == x, "equals " .. tostring(x)) end
		function m:is_true() return check(v == true, "is_true") end
		function m:is_nil() return check(v == nil, "is_nil") end
		function m:gt(x) return check(type(v) == "number" and v > x, "gt " .. tostring(x)) end
		function m:matches(p) return check(type(v) == "string" and v:find(p) ~= nil, "matches " .. p) end
		function m:is_file() return check(type(v) == "string" and fs.exists(v), "is_file") end
		return m
	end
	local fake = {
		expect = function(_, v, msg) return matcher(v, msg, false) end,
		expect_all = function(_, body) body() end,
		skip = function(_, reason) rec.skipped = reason; error(ABORT) end,
		use = function() return probe or { code = 0, output = "", deprecations = {} } end,
	}
	local rule
	for _, r in ipairs(standards.rules()) do
		if r.id == id then
			rule = r
		end
	end
	assert(rule, "no rule " .. id)
	local ok, err = pcall(rule.check, fake, { project = standards.project(root), cfg = standards.defaults, fixtures = {} })
	if not ok and err ~= ABORT then
		rec.failures[#rec.failures + 1] = "raised: " .. tostring(err)
	end
	return rec
end

-- ── Every rule passes a compliant project ──────────────────────────────────────────────────────

prova.test("a fresh, retrofitted project passes every static rule", function(t)
	local root = project(t)
	t:expect_all(function()
		for _, r in ipairs(standards.rules()) do
			if not r.compiles then
				local rec = judge(r.id, root)
				t:expect(#rec.failures, r.id .. ": " .. table.concat(rec.failures, "; ")):equals(0)
				-- The resolver rule judges virtual workspaces only; the case below covers it.
				if r.id ~= "cargo/resolver" then
					t:expect(rec.skipped, r.id .. " ran rather than skipped"):is_nil()
				end
			end
		end
	end)
end)

prova.test("a compliant virtual workspace passes the cargo rules", function(t)
	local root = project(t, {
		["Cargo.toml"] = '[workspace]\nresolver = "3"\nmembers = ["crates/*"]\n\n[workspace.package]\nedition = "2024"\n',
		["crates/a/Cargo.toml"] = '[package]\nname = "a"\nversion = "0.1.0"\nedition.workspace = true\n',
		["src/lib.rs"] = false,
	})
	t:expect_all(function()
		for _, id in ipairs({ "cargo/resolver", "cargo/edition" }) do
			local rec = judge(id, root)
			t:expect(#rec.failures, id .. ": " .. table.concat(rec.failures, "; ")):equals(0)
			t:expect(rec.skipped, id .. " ran"):is_nil()
		end
	end)
end)

-- ── …and fails a project broken in exactly one way ─────────────────────────────────────────────

local NO_CI = MANIFEST:gsub("%[profiles%.ci%]\nmust_run = %[\"cargo\"%]\n", "")
local NO_UT = MANIFEST:gsub("%[profiles%.ut%][^%[]*", "")
local BARE_FLOOR = MANIFEST:gsub('">= 0%.30"', '"0.30"')
local OLD_FLOOR = MANIFEST:gsub('">= 0%.30"', '">= 0.20"')
local BRANCH_DEP = MANIFEST .. '\n[dependencies]\nkind = { git = "https://github.com/prova-rs/prova-kind", branch = "main" }\n'
local REV_DEP = MANIFEST .. '\n[dependencies]\nkind = { git = "https://github.com/prova-rs/prova-kind", rev = "abc123" }\n'

local CASES = {
	{ id = "repo/readme", broke = "no README", edits = { ["README.md"] = false } },
	{ id = "repo/readme", broke = "an empty README", edits = { ["README.md"] = "  \n" } },
	{ id = "repo/gitignore", broke = "no .gitignore", edits = { [".gitignore"] = false } },
	{ id = "prova-suite/manifest", broke = "no manifest", edits = { [".prova/prova.toml"] = false } },
	{ id = "prova-suite/requires-floor", broke = "a bare version, which is a caret range", edits = { [".prova/prova.toml"] = BARE_FLOOR } },
	{ id = "prova-suite/requires-floor", broke = "a floor below the org's", edits = { [".prova/prova.toml"] = OLD_FLOOR } },
	{ id = "prova-suite/proof-naming", broke = "a *_test.lua proof", edits = { ["proofs/old_test.lua"] = "-- old\n" } },
	{ id = "prova-suite/proof-naming", broke = "a *.test.lua proof", edits = { ["proofs/quality/old.test.lua"] = "-- old\n" } },
	{ id = "prova-suite/dependencies-pinned", broke = "a branch pin", edits = { [".prova/prova.toml"] = BRANCH_DEP } },
	{ id = "prova-suite/dependencies-pinned", broke = "a rev pin", edits = { [".prova/prova.toml"] = REV_DEP } },
	{ id = "prova-suite/ci-profile", broke = "no CI profile", edits = { [".prova/prova.toml"] = NO_CI } },
	{ id = "cargo/edition", broke = "no edition (Rust 2015)", edits = { ["Cargo.toml"] = '[package]\nname = "demo"\nversion = "0.1.0"\n' } },
	{ id = "cargo/edition", broke = "edition 2018", edits = { ["Cargo.toml"] = '[package]\nname = "demo"\nversion = "0.1.0"\nedition = "2018"\n' } },
	{ id = "cargo/edition", broke = "a member with no edition", edits = {
		["Cargo.toml"] = '[workspace]\nresolver = "2"\nmembers = ["crates/*"]\n',
		["crates/a/Cargo.toml"] = '[package]\nname = "a"\nversion = "0.1.0"\nedition = "2021"\n',
		["crates/b/Cargo.toml"] = '[package]\nname = "b"\nversion = "0.1.0"\n',
	} },
	{ id = "cargo/resolver", broke = "a virtual workspace with no resolver", edits = {
		["Cargo.toml"] = '[workspace]\nmembers = ["crates/*"]\n',
		["crates/a/Cargo.toml"] = '[package]\nname = "a"\nversion = "0.1.0"\nedition = "2021"\n',
	} },
	{ id = "cargo/ignores-target", broke = "target/ not ignored", edits = { [".gitignore"] = ".DS_Store\n" } },
	{ id = "cargo/quality-legs", broke = "no ut leg", edits = { [".prova/prova.toml"] = NO_UT } },
	{ id = "cargo/clippy-gated", broke = "clippy without -D warnings", edits = { ["proofs/quality/clippy.prova.lua"] = CLIPPY_PROOF:gsub('"%-D", "warnings"', '"-W", "clippy::pedantic"') } },
	{ id = "cargo/clippy-gated", broke = "the gate commented out", edits = { ["proofs/quality/clippy.prova.lua"] = "-- " .. CLIPPY_PROOF:gsub("\n", "\n-- ") } },
	{ id = "cargo/no-blanket-allows", broke = "#![allow(warnings)]", edits = { ["src/lib.rs"] = "#![allow(warnings)]\n" .. COMPLIANT["src/lib.rs"] } },
	{ id = "cargo/no-blanket-allows", broke = "#[allow(unused, clippy::all)] on an item", edits = { ["src/lib.rs"] = "#[allow(unused, clippy::all)]\n" .. COMPLIANT["src/lib.rs"] } },
	{ id = "cargo/quality-baseline", broke = "no committed floor", edits = { [".prova/baselines/quality.json"] = false } },
}

prova.test_each("{id} fails on {broke}", CASES, function(t, case)
	local rec = judge(case.id, project(t, case.edits))
	t:expect(rec.skipped, "the rule judged the project rather than skipping it"):is_nil()
	t:expect(#rec.failures, "the rule reported the violation"):gt(0)
end)

prova.test("no-retired-surface fails when prova reports a deprecation", function(t)
	local rec = judge("prova-suite/no-retired-surface", project(t), {
		code = 0,
		output = "",
		deprecations = { "warning: [plugins] is deprecated — use [dependencies]" },
	})
	t:expect(#rec.failures):gt(0)
end)

prova.test("no-blanket-allows leaves a single named lint alone", function(t)
	local root = project(t, { ["src/lib.rs"] = "#[allow(clippy::too_many_arguments)] // the FFI signature is fixed\n" .. COMPLIANT["src/lib.rs"] })
	t:expect(#judge("cargo/no-blanket-allows", root).failures):equals(0)
end)

prova.test("no-blanket-allows does not judge build output", function(t)
	local root = project(t, { ["target/debug/build/x/out/gen.rs"] = "#![allow(warnings)]\n" })
	t:expect(#judge("cargo/no-blanket-allows", root).failures):equals(0)
end)

prova.test("cargo/formatted fails on an unformatted crate", { requires = { "cargo" } }, function(t)
	local unformatted = project(t, { ["src/lib.rs"] = "pub fn answer()->u32{42}\n" }, "unformatted")
	t:expect(#judge("cargo/formatted", unformatted).failures):gt(0)
	t:expect(#judge("cargo/formatted", project(t, nil, "formatted")).failures):equals(0)
end)

-- ── A consumer's view: one real run of a project that adopts the package ──────────────────────

prova.test("a failing rule tells the reader why it exists, in a real run", function(t)
	local root = project(t, {
		["README.md"] = false,
		["proofs/standards.prova.lua"] = 'require("project-standards").check {}\n',
		[".prova/prova.toml"] = MANIFEST .. ('\n[dependencies]\nproject-standards = { path = "%s" }\n'):format(prova.root),
	}, "consumer")
	local r = shell.run({ prova.bin, "--tags", "static" }, { cwd = root, merge_stderr = true, timeout = "120s" })
	t:expect(r.code, "the run is red: " .. r.stdout):equals(1)
	t:expect(r.stdout, "the failure leads with the rule id and its reason"):contains("repo/readme — the first question about any repository")
end)

-- ── Profiles and waivers ───────────────────────────────────────────────────────────────────────

prova.test("profiles come from what is on disk", function(t)
	local docs = t:tempdir("docs")
	fs.write(path.join(docs, "README.md"), "# docs\n")
	t:expect(table.concat(standards.profiles(docs), ",")):equals("repo")
	t:expect(table.concat(standards.profiles(project(t)), ",")):equals("repo,cargo,prova-suite")
end)

prova.test_each("a waiver {what}", {
	{ what = "with a reason is waived", w = "a reason", today = "2026-01-01", verdict = "waived" },
	{ what = "with a future end is waived", w = { why = "x", ends = "2026-12-31" }, today = "2026-11-25", verdict = "waived" },
	{ what = "past its end turns red again", w = { why = "x", ends = "2026-11-01" }, today = "2026-11-25", verdict = "expired" },
	{ what = "with an end that is not a date is red", w = { why = "x", ends = "soon" }, today = "2026-11-25", verdict = "expired" },
}, function(t, case)
	t:expect((standards.waiver(case.w, case.today))):equals(case.verdict)
end)

-- ── The package is subject to its own standards ────────────────────────────────────────────────

standards.check {}
