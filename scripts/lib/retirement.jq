# A retirement is an immutable stop instruction, never submission or release proof.
type == "object"
and (keys == ["ci_run_id","commit","execution_run_id","reason","retired_at","schema"])
and .schema == 1
and .commit == $sha
and .ci_run_id == $run
and .execution_run_id == $execution
and (.commit | type == "string" and test("^[a-f0-9]{40}$"))
and (.ci_run_id | type == "string" and test("^[1-9][0-9]*$"))
and (.execution_run_id | type == "string" and test("^[1-9][0-9]*$"))
and (.reason | type == "string" and test("^[a-z][a-z0-9_]{0,99}$"))
and (.retired_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
and (.retired_at as $timestamp | try (($timestamp | fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $timestamp) catch false)
