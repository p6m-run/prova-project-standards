---@meta project-standards
--- prova-project-standards — the p6m project standards, as proofs.
---
--- Editor-only type stub for `require("project-standards")`: completion and signatures for
--- consumers. It ships nothing at runtime; keep it in step with init.lua's public API.

---@class standards.Waiver
---@field why string          # the reason a person reads in every run's skip line
---@field owner string?       # who answers for it
---@field ends string?        # YYYY-MM-DD; past it, the rule turns red again

---@class standards.CheckOpts
---@field except table<string, string|standards.Waiver>?  # rule id -> reason, or a dated waiver
---@field profiles string[]?  # profiles to ADD to what is detected ("repo", "prova-suite", "cargo")
---@field label string?       # the describe label (default "project standards")
---@field root string?        # the project to judge (default: the package running the check)
---@field today string?       # YYYY-MM-DD, for proving waivers; defaults to today (UTC)

---@class standards.Defaults
---@field prova_floor string
---@field edition_floor string
---@field resolvers string[]
---@field quality_legs string[]
---@field baseline string
---@field blanket_allows string[]

---@class standards.Rule
---@field id string           # the waiver key; never changes
---@field profile string
---@field title string
---@field why string
---@field requires string[]?
---@field compiles boolean?   # true when the rule runs cargo
---@field check fun(t: prova.TestContext, c: table)

---@class standards.Project
---@field root string
---@field cargo table?        # decoded Cargo.toml
---@field crates { rel: string, toml: table }[]
---@field manifest_rel string?
---@field manifest table?     # decoded prova manifest
---@field gitignore string?

local standards = {}

--- The org's bar, as data.
---@type standards.Defaults
standards.defaults = {}

--- Hold the project to the standards: declares one test per applicable rule.
---@param opts standards.CheckOpts?
function standards.check(opts) end

--- The profiles a project matches, from what is on disk.
---@param root string?
---@return string[]
function standards.profiles(root) end

--- Every rule, or those in the given profiles, in reporting order.
---@param profiles string[]?
---@return standards.Rule[]
function standards.rules(profiles) end

--- Everything the rules read about a project, gathered once.
---@param root string?
---@return standards.Project
function standards.project(root) end

--- A waiver's verdict on `today`: "waived" or "expired", and the text reported.
---@param w string|standards.Waiver|false
---@param today string
---@return string verdict
---@return string text
function standards.waiver(w, today) end

--- Proof files on a retired spelling (`*_test.lua`, `*.test.lua`).
---@param project standards.Project
---@return string[]
function standards.legacy_proof_files(project) end

--- Git dependencies not pinned to a tag.
---@param manifest table?
---@return { name: string, how: string }[]
function standards.unpinned_dependencies(manifest) end

--- Crates below the edition floor or with no edition.
---@param project standards.Project
---@param floor string
---@return string[]
function standards.edition_findings(project, floor) end

--- Attributes that switch off a whole lint group: "<file>:<line>: <attribute>".
---@param root string
---@param lints string[]
---@return string[]
function standards.blanket_allows(root, lints) end

--- Whether a proof runs clippy with -D warnings, and which file.
---@param project standards.Project
---@return boolean, string?
function standards.clippy_gated(project) end

--- `a < b` for dotted numeric versions.
---@param a string
---@param b string
---@return boolean
function standards.version_lt(a, b) end

--- The keys `check` accepts.
---@type table<string, boolean>
standards.REPO_OPTS = {}

return standards
