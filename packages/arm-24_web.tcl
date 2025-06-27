# armour/packages/arm-24_web.tcl - An enhanced, self-contained web interface for Armour (Final Version)

namespace eval ::arm::web {

    # This dictionary will store our active sessions: {session_id -> username}
    variable sessions [dict create]

    # --- CORE SERVER PROCEDURES ---

    # Main procedure to start the web server socket
    proc start_server {} {
        if {![::arm::cfg:get web:enable]} { return }
        set port [::arm::cfg:get web:port]
        if {[catch {socket -server ::arm::web::accept $port} sock]} {
            ::arm::debug 0 "\[@\] Armour: \x0304(error)\x03 Could not open server socket on port $port. Error: $sock"
            return
        }
        ::arm::debug 0 "\[@\] Armour: Starting web interface on port $port"
    }

    # This procedure is called when a new browser connects. It now handles everything.
    proc accept {sock addr p} {
        variable sessions
        fconfigure $sock -buffering line -translation lf

        if {[eof $sock] || [catch {gets $sock request_line}]} {
            catch {close $sock}; return
        }

        # --- Read Headers ---
        set headers [dict create]
        while {[gets $sock line] > 0 && $line ne "\r"} {
            if {[regexp {^([^:]+): (.*)} $line -> key value]} {
                dict set headers [string trim $key] [string trim $value]
            }
        }
        
        lassign $request_line method path version

        # --- Session Check & Access Control ---
        set user ""
        if {[dict exists $headers Cookie]} {
            set cookie_str [dict get $headers Cookie]
            if {[regexp {session_id=([^; ]+)} $cookie_str -> session_id] && [dict exists $sessions $session_id]} {
                set user [dict get $sessions $session_id]
                if {[::arm::userdb:get:level $user *] < [::arm::cfg:get web:level]} {
                    set user "" ; # Invalidate session if user's level is too low
                }
            }
        }

        # --- ROUTING LOGIC ---
        set post_data ""
        if {$method eq "POST"} {
            set content_length 0
            if {[dict exists $headers "Content-Length"]} { set content_length [dict get $headers "Content-Length"] }
            if {$content_length > 0} {
                set post_data [read $sock $content_length]
            }
        }
        
        # Security Gate: Handle unauthenticated users first.
        if {$user eq ""} {
            if {$path eq "/login"} {
                if {$method eq "POST"} {
                    process_login $sock $post_data
                } else {
                    # Serve the login page for GET /login
                    send_page $sock "Login" [login_page]
                }
            } else {
                # Not logged in and not requesting the login page, so redirect to it.
                redirect $sock "/login"
            }
        } else {
            # --- If we reach here, the user IS authenticated ---
            switch -exact -- $path {
                "/" {
                    send_page $sock "Dashboard" [dashboard_page]
                }
                "/lists" {
                    send_page $sock "Manage Lists" [lists_page]
                }
                "/users" {
                    send_page $sock "Manage Users" [users_page]
                }
                "/channels" {
                    send_page $sock "Manage Channels" [channels_page]
                }
                "/events" {
                    send_page $sock "Recent Events" [events_page]
                }
                "/login" {
                    redirect $sock "/" ; # Already logged in, go to dashboard
                }
                "/logout" {
                    logout_handler $sock $headers
                }
                "/add-entry" {
                    if {$method eq "POST"} { process_add_entry $sock $post_data $user } else { redirect $sock "/lists" }
                }
                "/remove-entry" {
                    if {$method eq "POST"} { process_remove_entry $sock $post_data } else { redirect $sock "/lists" }
                }
                "/update-access" {
                    if {$method eq "POST"} { process_update_access $sock $post_data } else { redirect $sock "/users" }
                }
                "/update-channel" {
                    if {$method eq "POST"} { process_update_channel $sock $post_data } else { redirect $sock "/channels" }
                }
                default {
                    send_page $sock "Not Found" "<h2>404 Not Found</h2>" "404 Not Found"
                }
            }
        }
        
        flush $sock
        catch {close $sock}
    }

    # --- UTILITY PROCEDURES ---
    
    proc url_decode {str} {
        regsub -all {\+} $str { } str
        while {[regexp -indices -- {%([0-9a-fA-F]{2})} $str match]} {
            set hex [string range $str [expr {[lindex $match 0] + 1}] [lindex $match 1]]
            scan $hex %x char_code
            set str [string replace $str [lindex $match 0] [lindex $match 1] [format %c $char_code]]
        }
        return $str
    }

    proc html_escape {str} {
        return [string map {& &amp; < &lt; > &gt; \" &quot;} $str]
    }

    proc redirect {sock location} {
        puts $sock "HTTP/1.0 302 Found\r\nLocation: $location\r\n\r\n"
    }

    proc send_page {sock title body {status "200 OK"}} {
        set nav ""
        if {$title ne "Login" && $title ne "Error"} {
            set nav {
                <nav>
                    <a href="/">Dashboard</a> | 
                    <a href="/lists">Lists</a> |
                    <a href="/users">Users</a> |
                    <a href="/channels">Channels</a> |
                    <a href="/events">Events</a> |
                    <a href="/logout">Logout</a>
                </nav>
                <hr>
            }
        }
        set html "<!DOCTYPE html><html><head><title>Armour - $title</title><link rel='stylesheet' href='https://unpkg.com/simpledotcss/simple.min.css'></head><body><main>$nav$body</main></body></html>"
        puts $sock "HTTP/1.0 $status\r\nContent-Type: text/html\r\nContent-Length: [string length $html]\r\n\r\n$html"
    }

    # --- ACTION HANDLERS ---
    
    proc process_login {sock post_data} {
        if {[catch {
            variable sessions
            set form_data [dict create]
            foreach pair [split $post_data &] {
                lassign [split $pair =] key value
                dict set form_data [url_decode $key] [url_decode $value]
            }

            set username ""; set password ""
            if {[dict exists $form_data username]} { set username [dict get $form_data username] }
            if {[dict exists $form_data password]} { set password [dict get $form_data password] }
            
            set authenticated 0
            
            if {$username ne "" && $password ne ""} {
                foreach {uid udata} $::arm::dbusers {
                    if {[string equal -nocase [dict get $udata user] $username]} {
                        if {[dict get $udata pass] eq [::arm::userdb:encrypt $password]} {
                            set authenticated 1
                        }
                        break
                    }
                }
            }

            if {$authenticated && [::arm::userdb:get:level $username *] >= [::arm::cfg:get web:level]} {
                set session_id [::sha1::sha1 -hex "[clock clicks][clock seconds][expr {rand()}]"]
                dict set sessions $session_id $username
                puts $sock "HTTP/1.0 302 Found\r\nSet-Cookie: session_id=$session_id; Path=/; HttpOnly; SameSite=Strict\r\nLocation: /\r\n\r\n"
            } else {
                send_page $sock "Login" [login_page "Invalid credentials or insufficient access level."]
            }
        } error_message]} {
            ::arm::debug 0 "\n\n\x0304FATAL LOGIN ERROR:\x03 $error_message\n$::errorInfo\n"
            send_page $sock "Error" "<h2>500 Internal Server Error</h2><p>The server encountered an unrecoverable error while processing your request. Please check the bot's log file for details.</p>" "500 Internal Server Error"
        }
    }

    proc logout_handler {sock headers} {
        variable sessions
        if {[dict exists $headers Cookie]} {
            if {[regexp {session_id=([^; ]+)} [dict get $headers Cookie] -> session_id]} {
                dict unset sessions $session_id
            }
        }
        puts $sock "HTTP/1.0 302 Found\r\nSet-Cookie: session_id=deleted; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT\r\nLocation: /login\r\n\r\n"
    }
    
    proc process_add_entry {sock post_data user} {
        set form_data [dict create]
        foreach pair [split $post_data &] {
            lassign [split $pair =] key value
            dict set form_data $key [url_decode $value]
        }
        
        ::arm::db:add [string toupper [string index [dict get $form_data list] 0]] \
            [dict get $form_data chan] [dict get $form_data method] [dict get $form_data value] \
            "$user (web)" [dict get $form_data action] "1:1:1" [dict get $form_data reason]

        redirect $sock "/lists"
    }

    proc process_remove_entry {sock post_data} {
        lassign [split $post_data =] key id
        ::arm::db:rem [url_decode $id]
        redirect $sock "/lists"
    }
    
    proc process_update_access {sock post_data} {
        set form_data [dict create]
        foreach pair [split $post_data &] {
            lassign [split $pair =] key value
            dict set form_data [url_decode $key] [url_decode $value]
        }
        set uid [dict get $form_data uid]
        set cid [dict get $form_data cid]
        set level [dict get $form_data level]

        ::arm::db:connect
        ::arm::db:query "UPDATE levels SET level='$level' WHERE uid='$uid' AND cid='$cid'"
        ::arm::db:close
        redirect $sock "/users"
    }

    proc process_update_channel {sock post_data} {
        set form_data [dict create]
        foreach pair [split $post_data &] {
            lassign [split $pair =] key value
            dict set form_data [url_decode $key] [url_decode $value]
        }
        set cid [dict get $form_data cid]
        
        ::arm::db:connect
        foreach {setting value} [dict items $form_data] {
            if {$setting eq "cid"} continue
            ::arm::db:query "UPDATE settings SET value='[::arm::db:escape $value]' WHERE cid='$cid' AND setting='[::arm::db:escape $setting]'"
            dict set $::arm::dbchans $cid $setting $value
        }
        ::arm::db:close
        redirect $sock "/channels"
    }

    # --- PAGE GENERATORS ---

    proc login_page {{error ""}} {
        if {$error ne ""} { set error "<p style='color:red;'>$error</p>" }
        set body "<h1>Armour Login</h1>$error<form method='POST' action='/login'><label>Username</label><input type='text' name='username' required><label>Password</label><input type='password' name='password' required><button type='submit'>Login</button></form>"
        return $body
    }

    proc dashboard_page {} {
        set wcount [dict size [dict filter $::arm::entries script {id data} {expr {[dict get $data type] eq "white"}}]]
        set bcount [dict size [dict filter $::arm::entries script {id data} {expr {[dict get $data type] eq "black"}}]]

        set body "<h1>Dashboard</h1>
        <div class='grid'>
            <article>
                <h4>Bot Status</h4>
                <ul>
                    <li><b>Bot Name:</b> [html_escape [::arm::cfg:get botname]]</li>
                    <li><b>Eggdrop Version:</b> [lindex $::version 0]</li>
                    <li><b>Armour Version:</b> [::arm::cfg:get version] (rev: [::arm::cfg:get revision])</li>
                    <li><b>Uptime:</b> [::arm::userdb:timeago $::uptime]</li>
                </ul>
            </article>
            <article>
                <h4>Database Stats</h4>
                <ul>
                    <li><b>Registered Users:</b> [dict size $::arm::dbusers]</li>
                    <li><b>Managed Channels:</b> [expr {[dict size $::arm::dbchans] - 1}]</li>
                    <li><b>Whitelist Entries:</b> $wcount</li>
                    <li><b>Blacklist Entries:</b> $bcount</li>
                </ul>
            </article>
        </div>"
        return $body
    }

    proc events_page {} {
        set body "<h1>Recent Events</h1>"
        append body "<table><thead><tr><th>Timestamp</th><th>User</th><th>Command</th><th>Parameters</th><th>Source</th></tr></thead><tbody>"
        ::arm::db:connect
        set rows [::arm::db:query "SELECT timestamp, user, command, params, bywho FROM cmdlog ORDER BY timestamp DESC LIMIT 25"]
        ::arm::db:close
        foreach row $rows {
            lassign $row ts user cmd params bywho
            append body "<tr>"
            append body "<td>[clock format $ts -format {%Y-%m-%d %H:%M:%S}]</td>"
            append body "<td>[html_escape $user]</td>"
            append body "<td>[html_escape $cmd]</td>"
            append body "<td>[html_escape $params]</td>"
            append body "<td>[html_escape $bywho]</td>"
            append body "</tr>\n"
        }
        append body "</tbody></table>"
        return $body
    }

    proc users_page {} {
        set body "<h1>User Management</h1>"
        append body "<table><thead><tr><th>User ID</th><th>Username</th><th>Account</th><th>Access Level</th><th>Action</th></tr></thead><tbody>"
        ::arm::db:connect
        set users [::arm::db:query "SELECT id, user, xuser FROM users ORDER BY user"]
        foreach user_row $users {
            lassign $user_row uid user xuser
            append body "<tr><td valign='top'>$uid</td><td valign='top'>[html_escape $user]</td><td valign='top'>[html_escape $xuser]</td><td>"
            set levels [::arm::db:query "SELECT cid, level FROM levels WHERE uid=$uid ORDER BY cid"]
            append body "<ul>"
            foreach level_row $levels {
                lassign $level_row cid level
                set chan_name [::arm::db:get chan channels id $cid]
                append body "<li>[html_escape $chan_name]: <form style='display:inline-block;' action='/update-access' method='POST'><input type='hidden' name='uid' value='$uid'><input type='hidden' name='cid' value='$cid'><input type='number' name='level' value='$level' style='width: 70px;'><button class='tertiary' type='submit'>Save</button></form></li>"
            }
            append body "</ul></td>"
            append body "<td valign='top'><button class='tertiary' disabled>Remove</button></td></tr>\n"
        }
        ::arm::db:close
        append body "</tbody></table>"
        return $body
    }
    
    # ***************************************************************
    # ** THIS IS THE MODIFIED PROCEDURE WITH THE FIX **
    # ***************************************************************
    proc channels_page {} {
        set body "<h1>Channel Management</h1>"
        
        ::arm::db:connect
        set channels [::arm::db:query "SELECT id, chan FROM channels WHERE chan != '*' ORDER BY chan"]
        foreach chan_row $channels {
            lassign $chan_row cid chan
            set settings [dict create]
            set setting_rows [::arm::db:query "SELECT setting, value FROM settings WHERE cid=$cid"]
            foreach setting_row $setting_rows {
                lassign $setting_row key val
                dict set settings $key $val
            }
            
            append body "<form action='/update-channel' method='POST'><fieldset><legend><h3>[html_escape $chan]</h3></legend>"
            append body "<input type='hidden' name='cid' value='$cid'>"

            # ** FIX: Check if keys exist before trying to access them **
            set current_mode ""
            if {[dict exists $settings mode]} { set current_mode [dict get $settings mode] }
            
            set url_val ""
            if {[dict exists $settings url]} { set url_val [html_escape [dict get $settings url]] }

            set desc_val ""
            if {[dict exists $settings desc]} { set desc_val [html_escape [dict get $settings desc]] }
            
            # Mode Setting
            append body "<label for='mode_$cid'>Mode</label><select id='mode_$cid' name='mode'>"
            foreach mode_option {on off secure} {
                set selected [expr {$current_mode eq $mode_option ? "selected" : ""}]
                append body "<option value='$mode_option' $selected>[string totitle $mode_option]</option>"
            }
            append body "</select>"
            
            # URL and Desc Settings
            append body "<label for='url_$cid'>URL</label><input type='text' id='url_$cid' name='url' value='$url_val'>"
            append body "<label for='desc_$cid'>Description</label><input type='text' id='desc_$cid' name='desc' value='$desc_val'>"
            
            append body "<button type='submit'>Update [html_escape $chan]</button></fieldset></form>"
        }
        ::arm::db:close
        
        return $body
    }

    proc lists_page {} {
        set add_form {
            <fieldset>
                <legend><h2>Add New Entry</h2></legend>
                <form action="/add-entry" method="POST">
                    <div class="grid">
                        <label for="list">List Type
                            <select id="list" name="list" required>
                                <option value="white">Whitelist</option>
                                <option value="black">Blacklist</option>
                            </select>
                        </label>
                        <label for="chan">Channel
                            <input type="text" id="chan" name="chan" value="*" required>
                        </label>
                    </div>
                    <div class="grid">
                         <label for="method">Method
                            <select id="method" name="method" required>
                                <option value="user">user</option>
                                <option value="host">host</option>
                                <option value="regex">regex</option>
                                <option value="text">text</option>
                                <option value="country">country</option>
                                <option value="asn">asn</option>
                                <option value="chan">chan</option>
                            </select>
                        </label>
                        <label for="action">Action
                             <select id="action" name="action" required>
                                <option value="A">Accept</option>
                                <option value="V">Voice</option>
                                <option value="O">Op</option>
                                <option value="B">Kickban</option>
                            </select>
                        </label>
                    </div>
                    <label for="value">Value (e.g., *!*@some.host, a bad word, etc.)</label>
                    <input type="text" id="value" name="value" required>
                    <label for="reason">Reason</label>
                    <input type="text" id="reason" name="reason" required>
                    <button type="submit">Add Entry</button>
                </form>
            </fieldset>
        }

        set body "<h1>Manage Lists</h1>$add_form"
        append body "<h2>Whitelist</h2><table><thead><tr><th>ID</th><th>Chan</th><th>Method</th><th>Value</th><th>Action</th><th>Reason</th><th></th></tr></thead><tbody>"
        foreach id [lsort -integer [dict keys $::arm::entries]] {
            dict with ::arm::entries $id { 
                if {$type eq "white"} { 
                    append body "<tr>"
                    append body "<td>$id</td><td>[html_escape $chan]</td><td>[html_escape $method]</td><td>[html_escape $value]</td><td>[::arm::list:action $id]</td><td>[html_escape $reason]</td>"
                    append body "<td><form action='/remove-entry' method='POST'><input type='hidden' name='id' value='$id'><button class='tertiary' type='submit'>Remove</button></form></td>"
                    append body "</tr>\n" 
                } 
            }
        }
        append body "</tbody></table><h2>Blacklist</h2><table><thead><tr><th>ID</th><th>Chan</th><th>Method</th><th>Value</th><th>Action</th><th>Reason</th><th></th></tr></thead><tbody>"
        foreach id [lsort -integer [dict keys $::arm::entries]] {
            dict with ::arm::entries $id { 
                if {$type eq "black"} { 
                    append body "<tr>"
                    append body "<td>$id</td><td>[html_escape $chan]</td><td>[html_escape $method]</td><td>[html_escape $value]</td><td>[::arm::list:action $id]</td><td>[html_escape $reason]</td>"
                    append body "<td><form action='/remove-entry' method='POST'><input type='hidden' name='id' value='$id'><button class='tertiary' type='submit'>Remove</button></form></td>"
                    append body "</tr>\n"
                } 
            }
        }
        append body "</tbody></table>"
        return $body
    }
}

# This line calls the procedure to start the server.
::arm::web::start_server
