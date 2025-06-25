# ------------------------------------------------------------------------------------------------
# Summarise AI Plugin
#
# Uses AI to summarise either:
#   - a nickname based on 10 random quotes referencing them; or
#   - channel chat activity from the last N mins
#
# Converts summary into an audio file via text-to-speech.
# Accepts an optional 'prompt' override to control how the summary is presented.
#
# ------------------------------------------------------------------------------------------------
#
# Usage:
#
#   summarise ?chan? [nick|mins|search] [prompt]
#
# ------------------------------------------------------------------------------------------------
#
# Examples:
#
# Summarise channel chatter from the last 60 mins (default period):
#   summarise
#
# Summarise channel chatter from the last 10 mins:
#   summmarise 10
#
# Go back 60 mins and summarise 10 mins of channel chatter:
#   summarise 60 10
#
# Summarise Empus from 10 random quotes he's in:
#   summarise Empus
#
# Summarise 10 random quotes that match *dungeon*:
#   summarise *dungeon*
#
# Summarise 10 random quotes that match *dungeon* and make it professional:
#   summarise #armour 10 Act professional
#
# Summarise MrBob from 10 random quotes, and act like a teenage girl:
#   summarise MrBob Act like a teenage girl
#
# ------------------------------------------------------------------------------------------------
#
# Requires plugins:
#   - openai (openai.tcl)
#   - speak  (speak.tcl)
# ------------------------------------------------------------------------------------------------



# ------------------------------------------------------------------------------------------------
namespace eval arm {
# ------------------------------------------------------------------------------------------------


# ---------------------------------------------------------------------------------------
# command                  plugin        level req.    binds enabled
# ---------------------------------------------------------------------------------------
set addcmd(summarise)   {  arm           1            pub msg dcc    }
set addcmd(sum)         {  arm           1            pub msg dcc    }


package require json
package require http 2
package require tls 1.7

bind cron - "0 * * * *" arm::ask:cron;          # -- hourly file cleanup cronjob, on the hour
bind cron - "30 */3 * * *" arm::ask:cron:image; # -- cronjob every 3 hours at 30mins past the hours

bind pubm - "*" arm::sumlog:pubm

# -- strip colour codes from string
proc sumlog:strip {string} {
    # -- formatting patterns
    set colours {\003([0-9]{1,2}(,[0-9]{1,2})?)?}
    set bold {\002}
    set italics {\035}
    set underline {\037}
    set reset {\017}
    set action {\001ACTION}

    # -- remove colours
    set stripped [regsub -all $colours $string ""]

    # -- remove bold
    set stripped [regsub -all $bold $stripped ""]

    # -- remove italics
    set stripped [regsub -all $italics $stripped ""]

    # -- remove underline
    set stripped [regsub -all $underline $stripped ""]

    # -- remove reset
    set stripped [regsub -all $reset $stripped ""]

    # -- fix action
    set stripped [regsub -all $action $stripped ""]
    set stripped [regsub -all {\001} $stripped ""]

    return $stripped
}

# -- log channel activity to file
proc sumlog:pubm {nick uhost hand chan text} {
    global botnick
    if {$nick eq $botnick} { return; }; # -- don't log self
    if {[string index $text 0] eq [cfg:get prefix]} { return; }
    if {[lindex $text 0] eq $botnick || [lindex $text 0] eq "$botnick:"} { return; }
    # -- check if channel is registered
    set cid [db:get id channels chan $chan]
    if {$cid eq ""} { return; }
    set file "./armour/logs/[cfg:get botname].$chan.log"
    set time [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
    set line "\[$time\] <$nick> $text"
    #debug 2 "sumlog:pubm: writing to $file: $line"
    exec echo "$line" >> $file
}


# -- get seconds since epoch by timestamp
proc sumlog:to:epoch {timestamp} {
    set pattern {%Y-%m-%d %H:%M:%S}
    return [clock scan $timestamp -format $pattern]
}

# -- get log lines within the last N period mins, optionally for 'snapshot' mins
proc sumlog:get:recent {logfile period {snapshot "0"}} {
    
    set start_epoch [expr {[clock seconds] - $period * 60}]; # -- start time in secs since epoch
    set end_epoch [expr $start_epoch + ($snapshot * 60)];    # -- end time in secs since epoch

    set lines ""
    set fd [open $logfile]
    while {[gets $fd line] >= 0} {
        if {[regexp {^\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\] (.+)$} $line -> timestamp text]} {
            set since_epoch [sumlog:to:epoch $timestamp]; # -- secs since epoch by timestamp
            # -- check if line is within period
            if {$since_epoch >= $start_epoch && $since_epoch <= $end_epoch} {
                set stripped [sumlog:strip $text]
                append lines "$stripped\\n"
                debug 2 "sumlog:get:recent: line: $stripped"
            }
        }
    }
    close $fd
    set lines [string trimright $lines "\\n"]; # -- remove trailing newline char
    return $lines
}

# -- summarise chat log
proc arm:cmd:sum {0 1 2 3 {4 ""} {5 ""}} { arm:cmd:summarise $0 $1 $2 $3 $4 $5 }
proc arm:cmd:summarise {0 1 2 3 {4 ""} {5 ""}} {
    lassign [proc:setvars $0 $1 $2 $3 $4 $5] type stype target starget nick uh hand source chan arg 

    set cmd "summarise"

    set defmins 60; # -- default mins if not given

    lassign [db:get id,user users curnick $nick] uid user
    set tnick ""; set period ""; set snapshot 0;
	if {[string index [lindex $arg 0] 0] eq "#"} {
		# -- channel name given
		set chan [lindex $arg 0]
        if {[string is digit [lindex $arg 1]]} {
            # -- next arg is mins, to summarise from last N mins of chat history
            set isquote 0
            set period [lindex $arg 1]
            set prompt [lrange $arg 2 end]
            if {[string is digit [lindex $prompt 0]]} {
                set snapshot [lindex $prompt 0]
                set prompt [lrange $prompt 1 end]
            }
        } else {
            # -- next arg is a nickname, to summarise them from 10 random quotes
            set isquote 1
            set tnick [lindex $arg 1]
            set prompt [lrange $arg 2 end]
        }

	} else {
		# -- chan name not given, figure it out
		set chan [userdb:get:chan $user $chan]
        if {[string is digit [lindex $arg 0]]} {
            # -- next arg is mins, to summarise from last N mins of chat history
            set isquote 0
            set period [lindex $arg 0]
            set prompt [lrange $arg 1 end]
            if {[string is digit [lindex $prompt 0]]} {
                set snapshot [lindex $prompt 0]
                set prompt [lrange $prompt 1 end]
            }
        } else {
            # -- next arg is a nickname, to summarise them from 10 random quotes
            set isquote 1
            set tnick [lindex $arg 0]
            set prompt [lrange $arg 1 end]
        }
	}

    if {$chan eq "" || [string index $chan 0] ne "#"} {
        reply $type $target "\002usage:\002 summarise ?chan? \[nick|mins|search\] \[prompt\]"
        return;
    }

    set cid [db:get id channels chan $chan]
    if {$cid eq ""} { return; }; # -- chan not registered

    set allow [userdb:isAllowed $nick $cmd $chan $type]
    if {[userdb:isIgnored $nick $cid]} { set allow 0 }; # -- check if user is ignored
    if {!$allow} { return; }; # -- client cannot use command

    set ison [arm::db:get value settings setting "summarise" cid $cid]
    set ison "on"; # -- TODO: remove this line when setting is enabled
    if {$ison ne "on"} {
        # -- summarise plugin loaded, but setting not enabled on chan
        debug 1 "\002cmd:summarise:\002 summarise not enabled on $chan. to enable, use: \002modchan $chan summarise on\002"
        reply $type $target "\002error:\002 summarise not enabled. to enable, use: \002modchan $chan summarise on\002"
        return;
    }

    if {$isquote} {
        # -- NICK QUOTE SEARCH
        if {$prompt eq ""} {
            set prompt "Make it funny and be sarcastic."
        }
        if {[regexp -- {\*} $tnick]} {
            # -- wildcard search in quotes
            set nicksearch 0
            set search $tnick
            regsub -all {\*} $search % search
            regsub -all {\?} $search _ search
            set query "SELECT quote FROM quotes WHERE cid=$cid AND lower(quote) LIKE '[string tolower [string map {"*" "%"} $search]]' ORDER BY RANDOM() LIMIT 10"
        } else { 
            # -- search quotes based on referenced nick
            set nicksearch 1
            set search $tnick
            set query "SELECT quote FROM quotes WHERE cid=$cid AND (lower(quote) LIKE '%<[string tolower $tnick]>%'\
                OR lower(quote) LIKE '%<+[string tolower $tnick]>%' \
                OR lower(quote) LIKE '%<@[string tolower $tnick]>%' \
                OR lower(quote) LIKE '%[string tolower $tnick] |%') \ORDER BY RANDOM() LIMIT 10"
            set prompt "Focus on summarising only $tnick. $prompt"
        }
        
        db:connect
        #debug 0 "cmd:summarise: query: $query"
        set lines [db:query $query]
        db:close
        set num [llength $lines]
        if {$num eq 0} {
            reply $type $target "\002error:\002 no quotes found for $search"
            return;
        }
        set what [join $lines \\n]

        # -- END NICK QUOTE SEARCH
    } else {

        # -- recent file log search

        if {$period eq ""} {
            set period $defmins
        }

        if {$snapshot eq ""} { set snapshot $period }

        if {$period > 180} {
            reply $type $target "\002error:\002 maximum summarise period is 180 minutes."
            return;
        } elseif {$period < $snapshot} {
            reply $type $target "\002error:\002 snapshot period cannot be greater than summarise period."
            return;
        }

        debug 2 "\002cmd:summarise:\002 summarising $chan for last $period mins with snapshot period of $snapshot mins"

        set file "./armour/logs/[cfg:get botname].$chan.log"

        if {![file exists $file]} {
            reply $type $target "\002error:\002 no chat log found for $chan."
            return;
        }

        set what [sumlog:get:recent $file $period $snapshot]

        if {$what eq ""} {
            reply $type $target "$nick: no recent chat log found in the last $period minutes."
            return;
        }

        # -- send the query to OpenAI
        debug 0 "\002cmd:summarise:\002 $nick is asking ChatGPT for $chan summary of last $period mins"

    }

    #debug 2 "\002cmd:summarise:\002 what: $what"

    set response [summarise:query $what $cid $uid $type,[split $nick],$chan $prompt]; # -- send query to OpenAI
    #debug 3 "\002cmd:summarise:\002 response: $response"
    set iserror [string index $response 0]
    set response [string range $response 2 end]

    if {$iserror eq 1} {
        reply $type $target "\002openai error:\002 $response"
        return;
    }

    set eresponse $response
    regsub -all {"} $response {\"} eresponse; # -- escape quotes in response
    regsub -all {\{} $response {"} response; # -- fix curly braces
    regsub -all {\}} $response {"} response; # -- fix curly braces 
    
    #debug 1 "\002cmd:summarise:\002: OpenAI answer: $response"

    # -- convert response to TTS
    set iserror [speak:query $eresponse]
    if {[lindex $iserror 0] eq 1} {
        reply $type $target "\002 speech error:\002 [lrange $iserror 1 end]"
        return;
    }
    set ref [lindex $iserror 1]
    if {!$isquote} { 
        # -- summarise recent chan chatter
        set what "summarise last $period minutes from $chan"
    } else {
        # -- summarise random quotes from a nick
        set what "summarise $search from random quote references in $chan"
    }
    set rowid [ask:abstract:insert speak $nick $user $cid $ref $what]
    reply $type $target "$nick: $ref (\002id:\002 $rowid\002)\002"

    # -- create log entry for command use
    log:cmdlog BOT * $cid $user $uid [string toupper $cmd] [join $arg] $source "" "" ""
}

# -- send ChatGPT API queries
proc summarise:query {what cid uid key userprefix} {
    variable ask
    http::config -useragent "mozilla" 
    http::register https 443 [list ::tls::socket -autoservername true]
    set ::http::defaultCharset utf-8

    # -- query config
    # -- set API URL based on service
    switch -- [cfg:get ask:service] {
        openai     { set cfgurl "https://api.openai.com/v1/chat/completions" }
        perplexity { set cfgurl "https://api.perplexity.ai/chat/completions" }
        default    { set cfgurl "https://api.openai.com/v1/chat/completions"}
    }
    set token [cfg:get ask:token *]
    set org [cfg:get ask:org *]
    set model [cfg:get ask:model *]
    set model "gpt-4o"
    set timeout [expr [cfg:get ask:timeout *] * 20000]

    # -- POST data
    # {
    #    "model": "gpt-3.5-turbo",
    #    "messages": [{"role": "user", "content": "What is the capital of Australia?"}],
    #    "temperature": 0.7
    # }

    #debug 4 "summarise:query: what: $what"
    
    regsub -all {"} $what {\\"} ewhat;           # -- escape quotes in question
    #regsub -all {<} $ewhat {\<} ewhat;           # -- escape lt
    #regsub -all {>} $ewhat {\>} ewhat;           # -- escape gt
    #regsub -all {\\n} $ewhat {\\\n} ewhat;       # -- retain newlines
    #putlog "summarise:query: ewhat: $ewhat"
    #set ewhat $what
    set ewhat [encoding convertto utf-8 $ewhat]; # -- convert to utf-8
    #putlog "summarise:query: ewhat now (utf8 convert): $ewhat"
    #set ewhat $what

    # -- get any user & chan specific askmode
    set lines [cfg:get speak:lines *]
    set prefix "Answer in $lines lines or less" 
    set system [cfg:get ask:prefix *]
    if {[regexp -- {Answer in \d+ lines or less.} $system]} { set system "" }; # -- remove old default prefix user hasn't changed
    if {$system ne ""} { set prefix "$prefix. $system" }
    set mode "$prefix."
    set systemrole [cfg:get ask:system *] 
    set systemrole "The below is an IRC channel chat log.  Summarise it like a story but don't include the <>, pretend each nickname said that line. "
    if {$userprefix eq ""} {
        set userprefix "Make it funny and be sarcastic."
    }
    append systemrole "$userprefix.\\n"
    if {$systemrole ne ""} {
        # -- add system role instruction
        regsub -all {"} $systemrole {\\"} systemrole
        set ask($key) "{\"role\": \"system\", \"content\": \"$systemrole\"}, {\"role\": \"user\", \"content\": \"$mode $ewhat\"}"
    } else {
        set ask($key) "{\"role\": \"user\", \"content\": \"$mode $ewhat\"}"
    }

    set json "{\"model\": \"$model\", \"messages\": \[$ask($key)\], \"temperature\": [cfg:get ask:temp *]}"

    debug 3 "\002summarise:query:\002 POST JSON: $json"

    catch {set tok [http::geturl $cfgurl \
        -method POST \
        -binary 1 \
        -query $json \
        -headers [list "Authorization" "Bearer $token" "OpenAI-Organization" "$org" "Content-Type" "application/json"] \
        -timeout $timeout \
        -keepalive 0]} error

    # -- connection handling abstraction
    set iserror [ask:errors $cfgurl $tok $error]
    if {[lindex $iserror 0] eq 1} { return $iserror; }; # -- errors
    
    set json [http::data $tok]
    debug 5 "\002summarise:query:\002 response JSON: $json"
    set data [json::json2dict $json]
    http::cleanup $tok

    if {[dict exists $data error message]} {
        set errmsg [dict get $data error message]
        debug 0 "\002summarise:query:\002 OpenAI error: $errmsg"
        if {[string match "*could not parse the JSON body of your request*" $errmsg]} {
            # -- request error; invalid chars
            #debug 0 "\002ask:query:\002 invalid request characters"
            return "0 sorry, I didn't understand some invalid request characters."
        } else {
            return "1 $errmsg"
        }
    }
    set choices [dict get $data choices]
    set message [dict get [join $choices] message]
    set content [dict get $message content]

    debug 5 "\002summarise:query:\002 content: $content"
    return "0 $content"
}


# -- abstraction to check for HTTP errors
proc summarise:errors {cfgurl tok error} {
    debug 0 "\002ask:errors:\002 checking for errors...(error: $error)"
    if {[string match -nocase "*couldn't open socket*" $error]} {
        debug 0 "\002ask:errors:\002 could not open socket to $cfgurl."
        http::cleanup $tok
        return "1 socket"
    } 
    
    set ncode [http::ncode $tok]
    set status [http::status $tok]
    
    if {$status eq "timeout"} { 
        debug 0 "\002ask:errors:\002 connection to $cfgurl has timed out."
        http::cleanup $tok
        return "1 timeout"
    } elseif {$status eq "error"} {
        debug 0 "\002ask:errors:\002 connection to $cfgurl has error."
        http::cleanup $tok
        return "1 connection"
    }
}

# -- generate a random file
# -- arm::randfile [length] [chars]
# -- length to use is provided by config option if not provided
# -- chars to randomise are defaulted if not provided
proc randfile {{ext "png"} {length ""} {chars "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"}} {
    set dir [cfg:get ask:path]
    if {$length eq ""} { set length 5 }
    set range [expr {[string length $chars]-1}]
    set avail 0
    while {!$avail} {
        set text ""
        for {set i 0} {$i < $length} {incr i} {
            set pos [expr {int(rand()*$range)}]
            append text [string range $chars $pos $pos]
        }
        if {![file exists "$dir/$text.$ext"]} { set avail 1; break; }
    }
    return $text
}




putlog "\[@\] Armour: loaded SummariseOpenAI plugin (summarise)"

# ------------------------------------------------------------------------------------------------
}; # -- end namespace
# ------------------------------------------------------------------------------------------------
