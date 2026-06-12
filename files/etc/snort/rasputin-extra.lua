-- rasputin-extra.lua — Rasputin's overrides on top of the snort.uc
-- generated config (snort-mgr setup output). Applied last via the
-- `snort.snort.include` UCI option, set by 99-rasputin to this file.
--
-- Two things to fix:
--
-- 1. snort.uc comments out the `alert_fast` output module and leaves
--    only `alert_json` active. The rasputin agent's IDS tailer
--    (agent/internal/ids/tailer.go in rasputin-control-plane) reads
--    `/var/log/snort/alert_fast.txt`, so we have to bring it back.
--    Caught on the CWWK bring-up 2026-06-08: alert_fast.txt stays at
--    0 bytes until this include lands.
--
-- 2. snort.uc sets `output.show_year = true`, which makes snort emit
--    timestamps as `YY/MM/DD-HH:MM:SS.uuuuuu` (the year goes at the
--    FRONT, not the end). The agent's parser regex (parser.go) expects
--    either year-less `MM/DD-...` or year-included `MM/DD/YYYY-...` —
--    YY/MM/DD doesn't match either. Toggle show_year off so timestamps
--    match the parser's "MM/DD" default expectation.
--
-- Anything you add here gets appended to the end of the generated
-- snort_conf.lua (see /usr/share/snort/templates/snort.uc); the last
-- assignment wins for global tables, so reassigning `alert_fast` here
-- overrides the (commented-out) template default cleanly.

alert_fast =
{
    file = true,
    packet = false,
    -- 100 MB per file before snort rotates; we tail alert_fast.txt and
    -- the agent's tailer handles rotation via inode-shrink detection.
    limit = 100,
}

-- snort_conf.lua's earlier `output = { show_year = true, ... }` left
-- the rest of the table intact; this mutates just the one field.
if output then
    output.show_year = false
end
