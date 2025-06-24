# armour/packages/arm-24_web.tcl - A self-contained web interface for Armour (Final Version)

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

        # --- Session Check ---
        set user ""
        if {[dict exists $headers Cookie]} {
            set cookie_str [dict get $headers Cookie]
            if {[regexp {session_id=([^; ]+)} $cookie_str -> session_id] && [dict exists $sessions $session_id]} {
                set user [dict get $sessions $session_id]
            }
        }

        # --- Security Gate ---
        if {$user eq "" && $path ne "/login"} {
            puts $sock "HTTP/1.0 302 Found\r\nLocation: /login\r\n"
            catch {close $sock}; return
        }

        # --- ROUTING ---
        if {$method eq "POST"} {
            set content_length 0
            if {[dict exists $headers "Content-Length"]} { set content_length [dict get $headers "Content-Length"] }
            set post_data [read $sock $content_length]
            
            if {$path eq "/login"} {
                process_login $sock $post_data
            }
        } elseif {$method eq "GET"} {
            set page_html ""
            switch -exact -- $path {
                "/"       { set page_html [dashboard_page] }
                "/lists"  { set page_html [lists_page] }
                "/login"  { set page_html [login_page] }
                "/logout" { logout_handler $sock; return }
                default   { set page_html "<h2>404 Not Found</h2>" }
            }
            puts $sock "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nContent-Length: [string length $page_html]\r\n\r\n$page_html"
        }
        
        flush $sock
        catch {close $sock}
    }

    # --- PAGE AND ACTION HANDLERS ---
    
    proc process_login {sock post_data} {
        variable sessions
        set form_data [dict create]
        foreach pair [split $post_data &] {
            lassign [split $pair =] key value
            dict set form_data $key [string map {+ " "} $value]
        }

        set username [dict get $form_data username]
        set password [dict get $form_data password]
        set authenticated 0
        
        foreach {uid udata} $::arm::dbusers {
            if {[string equal -nocase [dict get $udata user] $username]} {
                if {[dict get $udata pass] eq [::arm::userdb:encrypt $password]} {
                    set authenticated 1
                }
                break
            }
        }

        if {$authenticated && [::arm::userdb:get:level $username *] >= [::arm::cfg:get web:level]} {
            set session_id [::sha1::sha1 -hex "[clock clicks][clock seconds][expr {rand()}]"]
            dict set sessions $session_id $username
            puts $sock "HTTP/1.0 302 Found\r\nSet-Cookie: session_id=$session_id; Path=/; HttpOnly\r\nLocation: /\r\n"
        } else {
            set page_html [login_page "Invalid credentials or access level."]
            puts $sock "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nContent-Length: [string length $page_html]\r\n\r\n$page_html"
        }
    }

    proc logout_handler {sock} {
        puts $sock "HTTP/1.0 302 Found\r\nSet-Cookie: session_id=deleted; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT\r\nLocation: /login\r\n"
    }

    proc login_page {{error ""}} {
        if {$error ne ""} { set error "<p style='color:red;'>$error</p>" }
        set body "<h1>Armour Login</h1>$error<form method='POST' action='/login'><label>Username</label><input type='text' name='username' required><label>Password</label><input type='password' name='password' required><button type='submit'>Login</button></form>"
        return "<!DOCTYPE html><html><head><title>Login</title><link rel='stylesheet' href='https://unpkg.com/simpledotcss/simple.min.css'></head><body><main>$body</main></body></html>"
    }

    proc dashboard_page {} {
        set body "<h1>Armour Status</h1><nav><a href='/'>Dashboard</a> | <a href='/lists'>View Lists</a> | <a href='/logout'>Logout</a></nav><p>Uptime: [::arm::userdb:timeago $::uptime]</p>"
        return "<!DOCTYPE html><html><head><title>Dashboard</title><link rel='stylesheet' href='https://unpkg.com/simpledotcss/simple.min.css'></head><body><main>$body</main></body></html>"
    }

    proc lists_page {} {
        set body "<h1>Manage Lists</h1><nav><a href='/'>Dashboard</a> | <a href='/lists'>View Lists</a> | <a href='/logout'>Logout</a></nav><h2>Whitelist</h2><table><thead><tr><th>ID</th><th>Chan</th><th>Method</th><th>Value</th><th>Action</th><th>Reason</th></tr></thead><tbody>"
        foreach id [lsort -integer [dict keys $::arm::entries]] {
            dict with ::arm::entries $id { if {$type eq "white"} { append body "<tr><td>$id</td><td>$chan</td><td>$method</td><td>$value</td><td>[::arm::list:action $id]</td><td>$reason</td></tr>\n" } }
        }
        append body "</tbody></table><h2>Blacklist</h2><table><thead><tr><th>ID</th><th>Chan</th><th>Method</th><th>Value</th><th>Action</th><th>Reason</th></tr></thead><tbody>"
        foreach id [lsort -integer [dict keys $::arm::entries]] {
            dict with ::arm::entries $id { if {$type eq "black"} { append body "<tr><td>$id</td><td>$chan</td><td>$method</td><td>$value</td><td>[::arm::list:action $id]</td><td>$reason</td></tr>\n" } }
        }
        append body "</tbody></table>"
        return "<!DOCTYPE html><html><head><title>Lists</title><link rel='stylesheet' href='https://unpkg.com/simpledotcss/simple.min.css'></head><body><main>$body</main></body></html>"
    }
}

# This line calls the procedure to start the server.
::arm::web::start_server
