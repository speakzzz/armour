# armour/packages/arm-24_web.tcl - Self-contained Web Interface for Armour

namespace eval ::arm::web {

    # Helper procedure to build a full HTML page with a consistent style
    proc build_page {title body} {
        set botnick $::botnick
        set html "
        <!DOCTYPE html>
        <html lang='en'>
        <head>
            <meta charset='UTF-8'>
            <title>$title: $botnick</title>
            <link rel='stylesheet' href='https://unpkg.com/simpledotcss/simple.min.css'>
        </head>
        <body>
            <main>
                $body
            </main>
        </body>
        </html>"
        return $html
    }

    # Main procedure to start the web server socket
    proc start_server {} {
        if {![::arm::cfg:get web:enable]} { return }

        set port [::arm::cfg:get web:port]
        
        if {[catch {socket -server ::arm::web::accept $port} sock]} {
            ::arm::debug 0 "\[@\] Armour: \x0304(error)\x03 Could not open server socket on port $port. Is another service using it? Error: $sock"
            return
        }
        ::arm::debug 0 "\[@\] Armour: Starting self-contained web interface on port $port"
    }

    # This procedure is called when a new browser connects
    proc accept {sock addr p} {
        fconfigure $sock -buffering line
        fileevent $sock readable [list ::arm::web::handle_request $sock]
    }

    # This procedure handles the actual HTTP request and routes it to the correct page handler
    proc handle_request {sock} {
        if {[eof $sock] || [catch {gets $sock request_line}]} {
            catch {close $sock}
            return
        }
        
        while {[gets $sock line] > 0 && $line ne "\r"} {}
        
        lassign $request_line method path version

        set html ""
        set status "200 OK"

        if {$method eq "GET"} {
            switch -exact -- $path {
                "/"         { set html [dashboard_page] }
                "/lists"    { set html [lists_page] }
                default {
                    set html [build_page "Not Found" "<h2>404 Not Found</h2>"]
                    set status "404 Not Found"
                }
            }
        }
        
        puts $sock "HTTP/1.0 $status"
        puts $sock "Content-Type: text/html"
        puts $sock "Content-Length: [string length $html]\r\n"
        puts $sock $html
        
        close $sock
    }

    # Page Handler for the Dashboard
    proc dashboard_page {} {
        set uptime [::arm::userdb:timeago $::uptime]
        set mem [expr {[lindex [status mem] 1] / 1024}]
        
        set body "
            <h1>Armour Status</h1>
            <nav>
                <a href='/'>Dashboard</a>
                <a href='/lists'>View Lists</a>
            </nav>
            <p>This page provides a real-time overview of the bot's status.</p>
            <ul>
                <li><strong>Uptime:</strong> $uptime</li>
                <li><strong>Memory Usage:</strong> ${mem}K</li>
            </ul>
        "
        return [build_page "Dashboard" $body]
    }

    # Page Handler for the Blacklist/Whitelist Viewer
    proc lists_page {} {
        set body "
            <h1>Blacklists & Whitelists</h1>
            <nav>
                <a href='/'>Dashboard</a>
                <a href='/lists'>View Lists</a>
            </nav>
            <h2>Whitelist</h2>
            <table>
                <thead>
                    <tr><th>ID</th><th>Chan</th><th>Method</th><th>Value</th><th>Action</th><th>Reason</th></tr>
                </thead>
                <tbody>
        "
        foreach id [lsort -integer [dict keys $::arm::entries]] {
            dict with ::arm::entries $id {
                if {$type eq "white"} {
                    set action [::arm::list:action $id]
                    append body "<tr><td>$id</td><td>$chan</td><td>$method</td><td>$value</td><td>$action</td><td>$reason</td></tr>\n"
                }
            }
        }
        append body "</tbody></table><h2>Blacklist</h2><table><thead><tr><th>ID</th><th>Chan</th><th>Method</th><th>Value</th><th>Action</th><th>Reason</th></tr></thead><tbody>"
        
        foreach id [lsort -integer [dict keys $::arm::entries]] {
            dict with ::arm::entries $id {
                if {$type eq "black"} {
                    set action [::arm::list:action $id]
                    append body "<tr><td>$id</td><td>$chan</td><td>$method</td><td>$value</td><td>$action</td><td>$reason</td></tr>\n"
                }
            }
        }
        append body "</tbody></table>"
        
        return [build_page "Armour Lists" $body]
    }

}

# This line calls the procedure to start the server after this file has been loaded.
::arm::web::start_server
