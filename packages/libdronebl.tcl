package require http
package require tls
package provide dronebl 1.3

# This version has been modified to integrate properly with the Armour TCL script.
# It removes the faulty standalone init procedure that was causing the library to unload itself on a network timeout.

# prefer ::dns::resolve from tcllib over eggdrop's dnslookup
if {[catch {package require dns} 0]} {
	if {[llength [info commands dnslookup]]} {
		proc iplookup {what cmd args} {dnslookup $what $cmd $args}
	} else {
		putlog "No DNS resolver found. Install tcllib and libudp-tcl."
		return
	}
} else {
	proc iplookup {what cmd args} {
		set tok [dns::resolve $what]
		while {[dns::status $tok] == "connect"} { dns::wait $tok }
		if {[dns::status $tok] == "ok"} {
			set ip [dns::address $tok]
			$cmd $ip $what 1 $args
		} else {
			::dronebl::lasterror [dns::error $tok]
			set ip 0
			$cmd $ip $what 0 $args
		}
		dns::cleanup $tok
		return $ip
	}
}

namespace eval dronebl {

# ** MODIFIED key PROCEDURE (with DEBUG) **
# returns value set for rpckey by getting it from the Armour config
proc key {} {
    # MODIFIED: Get the key from Armour's config system.
    set key_value [::arm::cfg:get dronebl:key]
    # ADDED DEBUG: Log the retrieved key (obscure partially for safety)
    set log_key [string range $key_value 0 3]...[string range $key_value end-3 end]
    if {$key_value eq ""} { set log_key "<EMPTY>" }
    putlog "\002\[DEBUG dronebl::key\]:\002 Retrieved key: $log_key"
    # END DEBUG
    return $key_value
}

# prepares ::http::config headers
proc setHTTPheaders {} {
	global version
	if {![info exists version]} {
		set http [::http::config -useragent "TCL [info patchlevel] HTTP library"]
	} else {
		set http [::http::config -useragent "Eggdrop $version / TCL [info patchlevel] HTTP library"]
	}
	return true
}

# performs DNS lookup if necessary and returns an IP
proc host2ip {ip {host 0} {status 0} {attempt 0}} {
	if {$ip == ""} {
		return 0
	} elseif {[regexp {^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}} $ip]} {
		return $ip
	} elseif { $attempt > 2 } {
		[namespace current]::lasterror "Unable to resolve $ip."
		return 0
	} else {
		iplookup $ip [namespace current]::host2ip [incr attempt]
	}
}

# ** MODIFIED talk PROCEDURE (with HTTP ERROR HANDLING) **
# performs a connection to the DroneBL RPC2 service and returns the response
proc talk { query } {
    [namespace current]::setHTTPheaders
    ::http::register https 443 tls::socket
    # Add timeout to prevent hanging indefinitely
    set http [::http::geturl "https://dronebl.org/rpc2" -type "text/xml" -query $query -timeout 5000]
    set data [::http::data $http]
    set status [::http::status $http]
    set ncode [::http::ncode $http]
    # Clean up regardless of status
    catch {::http::cleanup $http}
    catch {::http::unregister https}

    if {$status ne "ok"} {
        # If status isn't ok, set an error and return empty
        [namespace current]::lasterror "HTTP Error connecting to DroneBL: Status '$status', Code '$ncode'"
        return ""
    } elseif {$data eq ""} {
        # Handle cases where status is ok but data is empty (less likely but possible)
        [namespace current]::lasterror "Received empty data from DroneBL API (Status: $status, Code: $ncode)."
        return ""
    }
    return $data ; # Return data only if status was ok and data wasn't empty
}

# ** MODIFIED lasterror PROCEDURE (with DEBUG) **
# keeps track of the last error
proc lasterror {args} {
	global [namespace current]::err
	if {![info exists [namespace current]::err]} { set [namespace current]::err "" }
	if {$args != ""} {
        # ADDED DEBUG: Log when error is set
        putlog "\002\[DEBUG dronebl::lasterror\]:\002 Setting error to: '$args'"
        # END DEBUG
		set [namespace current]::err $args
	}
	namespace upvar [namespace current] err _err
    # ADDED DEBUG: Log when error is retrieved (Optional - can be noisy)
    # putlog "\002\[DEBUG dronebl::lasterror\]:\002 Returning error: '$_err'"
    # END DEBUG
	return [concat $_err]
}

# ** MODIFIED checkerrors PROCEDURE (with EMPTY CHECK) **
# parses DroneBL response for errors; returns true if none, false if errors found + populates lasterror
proc checkerrors {args} {
    # ADD THIS BLOCK to handle empty input from talk proc
    if {$args eq ""} {
        # Don't overwrite lasterror if talk already set one (like HTTP Error)
        if {[string trim [[namespace current]::lasterror]] eq ""} {
             [namespace current]::lasterror "Received empty or invalid response from DroneBL API."
        }
        return false
    }
    # END OF ADDED BLOCK - rest of the proc remains the same
	if {[string match "*success*" $args]} {
		return true
	} else {
		if {[regexp {<code>(.+)</code>.+<message>(.+)</message>} $args - code message]} {
			set err "$code $message"
		} else {
			set err $args
		}
		[namespace current]::lasterror $err
		return false
	}
}

# ** MODIFIED submit PROCEDURE (with DEBUG and EMPTY LIST FIX) **
# generates query for submitting a host / IP to the DroneBL service
proc submit { hosts } {
	set key [[namespace current]::key]
	if {$key == ""} {
        [namespace current]::lasterror "DroneBL RPC Key is not set in armour.conf."
        # ADDED DEBUG: Log key check failure
        putlog "\002\[DEBUG dronebl::submit\]:\002 Failing because key is empty."
        # END DEBUG
        return false
    }
    # ADDED DEBUG: Log entry point
    putlog "\002\[DEBUG dronebl::submit\]:\002 Starting submit for hosts: '$hosts'"
    # END DEBUG

	set query "<?xml version=\"1.0\"?>
<request key=\"$key\">"

	set bantype {type="1"}
	set hosts [split $hosts]
	if {[string is integer -strict [lindex $hosts 0]]} {
		set bantype "type=\"[lindex $hosts 0]\""
		set hosts [lreplace $hosts 0 0]
	}

    # Trim empty elements from the list after potential type removal
    set hosts [lsearch -all -inline -not -exact $hosts ""] ; # <<< FIX IS HERE

	foreach host $hosts {
        # ADDED DEBUG: Before host2ip
        putlog "\002\[DEBUG dronebl::submit\]:\002 Calling host2ip for host: '$host'"
        # END DEBUG
		if {[set ip [[namespace current]::host2ip $host]] == 0} {
             # ADDED DEBUG: Log host2ip failure
             putlog "\002\[DEBUG dronebl::submit\]:\002 host2ip failed for '$host'. Current lasterror: '[[namespace current]::lasterror]'"
             # END DEBUG
             return false
         }
        # ADDED DEBUG: After host2ip success
        putlog "\002\[DEBUG dronebl::submit\]:\002 host2ip succeeded for '$host', result IP: '$ip'"
        # END DEBUG
		foreach ip1 [split $ip] {
			set query "$query
	<add ip=\"$ip1\" $bantype />"
		}
	}

	set query "$query
</request>"

    # ADDED DEBUG: Before talk
    putlog "\002\[DEBUG dronebl::submit\]:\002 Calling talk with query:\n$query"
    # END DEBUG
    set response [[namespace current]::talk $query]
    # ADDED DEBUG: After talk
    putlog "\002\[DEBUG dronebl::submit\]:\002 Response from talk: '$response'"
    # END DEBUG
	return [[namespace current]::checkerrors $response]
}

# generates query for setting an IP inactive in the DroneBL service
proc remove { ids } {
	set key [[namespace current]::key]
	if {$key == ""} {
        [namespace current]::lasterror "DroneBL RPC Key is not set in armour.conf."
        return false
    }

	set query "<?xml version=\"1.0\"?>
<request key=\"$key\">"

	foreach id [split $ids] {
		if {![string is integer -strict $id]} { [namespace current]::lasterror "$id is not an integer."; return false }
		set query "$query
	<remove id=\"$id\" />"
	}

	set query "$query
</request>"

	return [[namespace current]::checkerrors [[namespace current]::talk $query]]
}

# turns raw XML response from DroneBL into a list
proc listify { raw } {
	if {![[namespace current]::checkerrors $raw]} { return false }
	set res [regexp -linestop -inline -all {.+} $raw]
	set table {{ID IP {Ban type} Listed Timestamp}}

	foreach line $res {
		if {[regexp {ip="([^"]+)".+type="([^"]+)".+id="([^"]+)".+listed="([^"]+)".+timestamp="([^"]+)"} $line - ip type id listed timestamp]} {
			lappend table [list $id $ip $type $listed [clock format $timestamp -format {%Y.%m.%d %H:%M:%S}]]
		} elseif {[string match {<response type="success" />} $line]} {
			return {{{No matches.}}}
		}
	}
	return $table
}

# returns a nested list of matches where $ip is listed in the DroneBL
proc lookup { ips } {
	set key [[namespace current]::key]
	if {$key == ""} {
        [namespace current]::lasterror "DroneBL RPC Key is not set in armour.conf."
        return false
    }

	set switches [lsearch -all -regexp -inline $ips {^-+.*}]
	set listed {listed="1"}
	set limit {limit="10"}

	foreach thingy $switches {
		switch -regexp [string tolower $thingy] {
			-+active { set listed {listed="1"} }
			-+(u|i)n.+ { set listed {listed="0"} }
			-+.*(all|any) { set listed {listed="2"} }
			-+limit {
				if {[llength $ips] == 1} { set ips [split $ips] }
				set idx [expr [lsearch -exact $ips $thingy] + 1]
				set arg [lindex $ips $idx]
				if {[string is integer -strict $arg]} {
					set limit "limit=\"$arg\""
					set ips [lreplace $ips $idx $idx]
				}
				set ips [join $ips]
			}
		}
	}

	set query "<?xml version=\"1.0\"?>
<request key=\"$key\">"

	foreach ip [split $ips] {
		if {[lsearch -exact $switches $ip] != -1} { continue }
		if {[regexp -nocase {[a-z]} $ip] && [set ip [[namespace current]::host2ip $ip]] == 0} { return false }

		if {[string is integer -strict $ip]} {
			set query "$query
	<lookup id=\"$ip\" />"
		} else {
			foreach ip1 [split $ip] {
				set query "$query
	<lookup ip=\"$ip1\" $limit $listed />"
			}
		}
	}

	set query "$query
</request>"

	[namespace current]::setHTTPheaders
	return [[namespace current]::listify [[namespace current]::talk $query]]
}

# returns a nested list of records submitted via your RPC key
proc records {{txt ""}} {
	set key [[namespace current]::key]
	if {$key == ""} { return }

	set switches [lsearch -all -regexp -inline $txt {^-+.*}]
	set listed {listed="1"}
	set limit {limit="10"}

	foreach thingy $switches {
		switch -regexp [string tolower $thingy] {
			-+active { set listed {listed="1"} }
			-+(u|i)n.+ { set listed {listed="0"} }
			-+.*(all|any) { set listed {listed="2"} }
			-+limit {
				if {[llength $txt] == 1} { set txt [split $txt] }
				set idx [expr [lsearch -exact $txt $thingy] + 1]
				set arg [lindex $txt $idx]
				if {[string is integer -strict $arg]} {
					set limit "limit=\"$arg\""
					set txt [lreplace $txt $idx $idx]
				}
				set txt [join $txt]
			}
		}
	}

	set query "<?xml version=\"1.0\"?>
<request key=\"$key\">
	<records $listed $limit />
</request>"

	[namespace current]::setHTTPheaders
	return [[namespace current]::listify [[namespace current]::talk $query]]
}

# returns a nested list of {Class Description} {1 {Testing class.}} {2 {Sample data...}} etc.
proc classes {{txt ""}} {
	[namespace current]::setHTTPheaders
	::http::register https 443 tls::socket
	set http [::http::geturl "https://dronebl.org/classes?format=txt"]
	set data [::http::data $http]
	::http::unregister https
	set res [regexp -linestop -inline -all {.+} [::http::data $http]]

	set classlist {{Class Description}}

	foreach line $res {
		set words [split $line]
		set firstword [lindex $words 0]
		set words [join [lreplace $words 0 0]]
		if {$txt == "" || [lsearch [split $txt] $firstword] != -1} {
			lappend classlist [list $firstword $words]
		}
	}
	return $classlist
}

}; # end namespace declaration
