
# ------------------------------------------------------------------------------------------------
# Poll / Voting System Plugin for Armour (v1.4)
# ------------------------------------------------------------------------------------------------
#
# Allows users with permission to create and manage polls in a channel.
# v1.1 - Added automatic database table creation.
# v1.2 - Fixed argument parsing and a bug in the vote command.
# v1.3 - Fixed missing database connection in 'close' and 'results' functions.
# v1.4 - Changed vote instruction to use the bot's name instead of a hardcoded prefix.
#
# ------------------------------------------------------------------------------------------------

# -- Register commands with Armour's command handler
set addcmd(poll) { polls 25 pub msg dcc }
set addcmd(vote) { polls 1  pub msg dcc }

# --- Main Dispatcher for the '!poll' command ---
proc polls:cmd:poll {0 1 2 3 {4 ""} {5 ""}} {
    lassign [proc:setvars $0 $1 $2 $3 $4 $5] type stype target starget nick uh hand source chan arg
    
    set action [string tolower [lindex $arg 0]]
    set poll_args [lrange $arg 1 end]

    switch -- $action {
        "new"     { polls:sub:new $type $nick $chan $poll_args }
        "results" { polls:sub:results $type $target $chan }
        "close"   { polls:sub:close $type $target $nick $chan }
        "list"    { polls:sub:list $type $target $chan }
        default   { reply $type $target "Usage: !poll <new|results|close|list>" }
    }
}

# --- Command to cast a vote ---
proc polls:cmd:vote {0 1 2 3 {4 ""} {5 ""}} {
    lassign [proc:setvars $0 $1 $2 $3 $4 $5] type stype target starget nick uh hand source chan arg
    
    set cid [db:get id channels chan $chan]
    if {$cid eq ""} { return } ; # Not a registered channel

    set poll_id [db:get id polls cid $cid status open]
    if {$poll_id eq ""} {
        reply notc $nick "There is no poll currently open in $chan."
        return
    }

    set option_num [lindex $arg 0]
    if {![string is integer $option_num] || $option_num <= 0} {
        reply notc $nick "Invalid vote. Please use the option number (e.g., !vote 2)."
        return
    }

    set option_id [db:get id poll_options poll_id $poll_id option_num $option_num]
    if {$option_id eq ""} {
        reply notc $nick "That is not a valid option number for the current poll."
        return
    }

    lassign [db:get id,user users curnick $nick] uid user
    if {$uid eq ""} {
        reply notc $nick "You must be logged in to the bot to vote. Please login first."
        return
    }

    set voted_ts [clock seconds]
    db:connect
    if {[catch {db:query "INSERT INTO poll_votes (poll_id, voter_uid, voted_ts, option_id) VALUES ($poll_id, $uid, $voted_ts, $option_id)"} err]} {
        db:query "UPDATE poll_votes SET option_id = $option_id, voted_ts = $voted_ts WHERE poll_id = $poll_id AND voter_uid = $uid"
        set option_text [db:get option_text poll_options id $option_id]
        reply notc $nick "You have changed your vote to: \"$option_text\""
    } else {
        set option_text [db:get option_text poll_options id $option_id]
        reply notc $nick "Your vote for \"$option_text\" has been recorded."
    }
    db:close
}


# --- Helper procedure to create a new poll ---
proc polls:sub:new {type nick chan args} {
    # --- START OF CHANGE v1.4 ---
    global botnick
    # --- END OF CHANGE v1.4 ---
    lassign [db:get id,user users curnick $nick] uid user
    set required_level [cfg:get polls:allow_create $chan]
    if {$required_level eq ""} { set required_level 100 }
    set user_level [userdb:get:level $user $chan]

    if {$user_level < $required_level} {
        reply $type $chan "$nick: You do not have permission to create a poll (requires level $required_level)."
        return
    }

    set cid [db:get id channels chan $chan]
    set open_poll [db:get id polls cid $cid status open]
    if {$open_poll ne ""} {
        reply $type $chan "A poll is already running in this channel. Please close it first with !poll close."
        return
    }

    set raw_parts [regexp -all -inline -- {"(.*?)"} $args]
    set clean_parts [list]
    foreach {fullmatch submatch} $raw_parts {
        lappend clean_parts $submatch
    }

    if {[llength $clean_parts] < 3} {
        reply $type $chan "Usage: !poll new \"<Question>\" \"<Option 1>\" \"<Option 2>\" ..."
        return
    }
    
    set question [lindex $clean_parts 0]
    set options [lrange $clean_parts 1 end]

    if {[llength $options] > 10} {
        reply $type $chan "Sorry, a maximum of 10 options are allowed for a poll."
        return
    }

    set created_ts [clock seconds]
    
    db:connect
    db:query "INSERT INTO polls (cid, question, creator_uid, created_ts, status) VALUES ($cid, '[db:escape $question]', $uid, $created_ts, 'open')"
    set poll_id [db:last:rowid]

    set option_num 1
    foreach option_text $options {
        db:query "INSERT INTO poll_options (poll_id, option_num, option_text) VALUES ($poll_id, $option_num, '[db:escape $option_text]')"
        incr option_num
    }
    db:close

    reply $type $chan "\002New Poll Started by $nick (ID: $poll_id):\002 $question"
    
    set options_line ""
    set option_num 1
    foreach option_text $options {
        append options_line "\002$option_num:\002 $option_text | "
        incr option_num
    }
    set options_line [string trimright $options_line " | "]
    reply $type $chan $options_line

    # --- START OF CHANGE v1.4 ---
    reply $type $chan "To vote, type \002$botnick vote <number>\002"
    # --- END OF CHANGE v1.4 ---
}

# --- Helper procedure to show poll results ---
proc polls:sub:results {type target chan} {
    set cid [db:get id channels chan $chan]
    set poll_id [db:get id polls cid $cid status open]
    if {$poll_id eq ""} {
        reply $type $target "There is no poll currently open in $chan."
        return
    }
    set question [db:get question polls id $poll_id]
    reply $type $target "\002Current Results for Poll $poll_id:\002 $question"

    db:connect
    set options [db:query "SELECT id, option_num, option_text FROM poll_options WHERE poll_id = $poll_id ORDER BY option_num ASC"]
    set total_votes [lindex [join [db:query "SELECT COUNT(*) FROM poll_votes WHERE poll_id = $poll_id"]] 0]

    foreach option $options {
        lassign $option option_id option_num option_text
        set vote_count [lindex [join [db:query "SELECT COUNT(*) FROM poll_votes WHERE option_id = $option_id"]] 0]
        
        if {$total_votes > 0} {
            set percentage [expr {round(100.0 * $vote_count / $total_votes)}]
            set bar_fill [string repeat "█" [expr {round($percentage / 10.0)}]]
            set bar_empty [string repeat "░" [expr {10 - round($percentage / 10.0)}]]
            set result_line "\002$option_num:\002 $option_text ($vote_count votes) - \[$bar_fill$bar_empty\] $percentage%"
        } else {
            set result_line "\002$option_num:\002 $option_text (0 votes)"
        }
        reply $type $target $result_line
    }
    db:close
}

# --- Helper procedure to close a poll ---
proc polls:sub:close {type target nick chan} {
    set cid [db:get id channels chan $chan]
    set poll_id [db:get id polls cid $cid status open]
    if {$poll_id eq ""} {
        reply $type $target "There is no poll currently open in $chan."
        return
    }

    lassign [db:get id,user users curnick $nick] uid user
    set creator_uid [db:get creator_uid polls id $poll_id]
    set user_level [userdb:get:level $user $chan]
    set required_level [cfg:get polls:allow_close $chan]
    if {$required_level eq ""} { set required_level 250 }

    if {$uid != $creator_uid && $user_level < $required_level} {
        reply $type $target "Sorry, only the poll creator or someone with level $required_level or higher can close the poll."
        return
    }

    reply $type $target "Poll $poll_id has been closed by $nick. Final results:"
    polls:sub:results $type $target $chan
    
    db:connect
    db:query "UPDATE polls SET status = 'closed' WHERE id = $poll_id"
    db:close
}

# --- Helper procedure to list open polls ---
proc polls:sub:list {type target chan} {
    set cid [db:get id channels chan $chan]
    set poll_info [db:get id,question polls cid $cid status open]
    if {$poll_info eq ""} {
        reply $type $target "There are no active polls in $chan."
    } else {
        lassign $poll_info poll_id question
        reply $type $target "Active poll in $chan is ID $poll_id: \"$question\""
    }
}

# --- Database Initialization Procedure ---
proc polls:db:init {} {
    debug 1 "\[Polls] Initializing database schema..."
    db:connect
    db:query "CREATE TABLE IF NOT EXISTS polls (id INTEGER PRIMARY KEY AUTOINCREMENT, cid INTEGER NOT NULL, question TEXT NOT NULL, creator_uid INTEGER NOT NULL, created_ts INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'open');"
    db:query "CREATE TABLE IF NOT EXISTS poll_options (id INTEGER PRIMARY KEY AUTOINCREMENT, poll_id INTEGER NOT NULL, option_num INTEGER NOT NULL, option_text TEXT NOT NULL);"
    db:query "CREATE TABLE IF NOT EXISTS poll_votes (poll_id INTEGER NOT NULL, voter_uid INTEGER NOT NULL, voted_ts INTEGER NOT NULL, option_id INTEGER NOT NULL, UNIQUE(poll_id, voter_uid));"
    db:close
    debug 1 "\[Polls] Database schema check complete."
}

# --- SCRIPT INITIALIZATION ---
polls:db:init
putlog "\[A\] Armour: loaded plugin: polls"
