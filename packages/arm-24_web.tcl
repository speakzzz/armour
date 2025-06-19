# Web Interface
#
# ------------------------------------------------------------------------------------------------
namespace eval ::arm::web {
    
    # In ./armour/packages/arm-24_web.tcl

proc ::arm::web::start_server {} {
    if {![::arm::cfg:get web:enable]} { return }

    #
    # This path now includes the nested directory to correctly find httpd.tcl
    #
    set httpd_package_dir "tclhttpd-3.5.1/tclhttpd3.5.1" # <-- The only change is here
    set httpd_path [file join [file dirname [info script]] $httpd_package_dir "httpd.tcl"]

    if {![file readable $httpd_path]} {
        ::arm::debug 0 "\[@\] Armour: \x0304(error)\x03 Web server script not found at expected path: $httpd_path"
        return
    }

    # Source the main httpd script from its own directory
    if {[catch {source $httpd_path} err]} {
        ::arm::debug 0 "\[@\] Armour: \x0304(error)\x03 Failed to load tclhttpd. Tcl error: $err"
        return
    }

    set port [::arm::cfg:get web:port]
    ::arm::debug 0 "\[@\] Armour: Starting web interface on port $port"
    
    # This is the correct command when sourcing the file directly
    Httpd_Server $port [list ::arm::web::router]
}

    # Simple request router
    proc router {sock suffix} {
        # In a real implementation, you would have session/cookie based authentication here
        
        switch -exact -- $suffix {
            "/" { dashboard_page $sock }
            default { ::Httpd_ReturnData $sock "text/html" "<h2>404 Not Found</h2><p>The requested page '$suffix' was not found.</p>" "404 Not Found" }
        }
    }
    
    # Page Handler for the Dashboard
    proc dashboard_page {sock} {
        set botnick $::botnick
        set uptime [::arm::userdb:timeago $::uptime]
        set mem [expr {[lindex [status mem] 1] / 1024}]
        set user_count [dict size $::arm::dbusers]
        set chan_count [expr {[dict size $::arm::dbchans] - 1}] ;# Subtract global channel
        
        set html "
        <!DOCTYPE html>
        <html lang='en'>
        <head>
            <meta charset='UTF-8'>
            <title>Armour Status: $botnick</title>
            <style>
                body { font-family: sans-serif; background-color: #f4f4f4; color: #333; }
                .container { max-width: 800px; margin: 2em auto; padding: 2em; background: #fff; border-radius: 8px; box-shadow: 0 0 10px rgba(0,0,0,0.1); }
                h1 { color: #0056b3; }
                strong { color: #555; }
            </style>
        </head>
        <body>
            <div class='container'>
                <h1>Armour Status: $botnick</h1>
                <ul>
                    <li><strong>Uptime:</strong> $uptime</li>
                    <li><strong>Memory Usage:</strong> ${mem}K</li>
                    <li><strong>Registered Users:</strong> $user_count</li>
                    <li><strong>Managed Channels:</strong> $chan_count</li>
                </ul>
            </div>
        </body>
        </html>"
        
        ::Httpd_ReturnData $sock "text/html" $html
    }
}

# Add this call to the very end of arm-23_init.tcl
# It will start the web server after everything else has loaded.
arm::web::start_server
