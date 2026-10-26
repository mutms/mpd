<?php
// Query runner behind mdl-agent-sql; started through agent/cli/run.php, so
// Moodle is loaded and $DB is the project's database.
//
// Arguments: <format> <limit> <write 0|1> <sql>

[$mdlagentformat, $mdlagentlimit, $mdlagentwrite, $mdlagentsql] = [$argv[1], (int)$argv[2], $argv[3] === '1', trim($argv[4])];
$mdlagentsql = rtrim($mdlagentsql, "; \t\n\r");
if ($mdlagentsql === '') {
    fwrite(STDERR, "mdl-agent-sql: no SQL given\n");
    exit(1);
}

$mdlagentreads = (bool)preg_match('/^\s*(select|with|show|explain|values)\b/i', $mdlagentsql);

// EXPLAIN and SHOW must reach the database as written: Moodle would append
// LIMIT (explaining a different query, or a syntax error after SHOW) or wrap
// them in a PostgreSQL cursor, which neither can run in.
$mdlagentverbatim = (bool)preg_match('/^\s*(show|explain)\b/i', $mdlagentsql);

// EXPLAIN ANALYZE executes its statement, so a change still needs --write.
if (preg_match('/^\s*explain\s+((?:\([^)]*\)\s*|(?:analy[sz]e|verbose|extended|partitions|format\s*=\s*\w+)\s+)*)(.*)$/is', $mdlagentsql, $mdlagentmatch)) {
    if (preg_match('/\banaly[sz]e\b/i', $mdlagentmatch[1]) && !preg_match('/^(select|with|values|table)\b/i', $mdlagentmatch[2])) {
        if (!$mdlagentwrite) {
            fwrite(STDERR, "mdl-agent-sql: EXPLAIN ANALYZE runs this statement and it changes data, add --write to run it\n");
            exit(1);
        }
    }
}

if (!$mdlagentreads) {
    if (!$mdlagentwrite) {
        fwrite(STDERR, "mdl-agent-sql: this statement changes data, add --write to run it\n");
        exit(1);
    }
    $DB->execute($mdlagentsql);
    echo "OK\n";
    exit(0);
}

// A recordset, not get_records_sql(): the first column need not be unique.
if ($mdlagentverbatim) {
    // No LIMIT and no cursor; the row limit is applied below while reading.
    (function () {
        $this->dboptions['fetchbuffersize'] = 0;
    })->call($DB);
    $mdlagentrs = $DB->get_recordset_sql($mdlagentsql);
} else {
    $mdlagentrs = $DB->get_recordset_sql($mdlagentsql, null, 0, $mdlagentlimit > 0 ? $mdlagentlimit + 1 : 0);
}
$mdlagentrows = [];
$mdlagentmore = false;
foreach ($mdlagentrs as $mdlagentrow) {
    if ($mdlagentlimit > 0 && count($mdlagentrows) >= $mdlagentlimit) {
        $mdlagentmore = true;
        break;
    }
    $mdlagentrows[] = (array)$mdlagentrow;
}
$mdlagentrs->close();

if ($mdlagentformat === 'json') {
    echo json_encode($mdlagentrows, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), "\n";
} else if (!$mdlagentrows) {
    echo "(no rows)\n";
} else {
    $mdlagentcell = function ($value) use ($mdlagentformat, $mdlagentverbatim): string {
        if ($value === null) {
            return 'NULL';
        }
        $value = str_replace(["\r", "\n", "\t"], ['\r', '\n', '\t'], (string)$value);
        if ($mdlagentformat === 'table' && !$mdlagentverbatim && mb_strlen($value) > 60) {
            $value = mb_substr($value, 0, 57) . '...';
        }
        return $value;
    };
    $mdlagentlines = [array_keys($mdlagentrows[0])];
    foreach ($mdlagentrows as $mdlagentrow) {
        $mdlagentlines[] = array_map($mdlagentcell, array_values($mdlagentrow));
    }
    if ($mdlagentformat === 'tsv') {
        foreach ($mdlagentlines as $mdlagentline) {
            echo implode("\t", $mdlagentline), "\n";
        }
    } else {
        $mdlagentwidths = [];
        foreach ($mdlagentlines as $mdlagentline) {
            foreach ($mdlagentline as $i => $value) {
                $mdlagentwidths[$i] = max($mdlagentwidths[$i] ?? 0, mb_strlen($value));
            }
        }
        foreach ($mdlagentlines as $n => $mdlagentline) {
            $out = [];
            foreach ($mdlagentline as $i => $value) {
                $out[] = $value . str_repeat(' ', $mdlagentwidths[$i] - mb_strlen($value));
            }
            echo rtrim(implode(' | ', $out)), "\n";
            if ($n === 0) {
                echo implode('-+-', array_map(fn($w) => str_repeat('-', $w), $mdlagentwidths)), "\n";
            }
        }
    }
}

if ($mdlagentmore) {
    fwrite(STDERR, "(more rows exist; showing the first {$mdlagentlimit}, raise --limit or use --limit=0)\n");
}
