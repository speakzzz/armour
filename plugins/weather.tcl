# ------------------------------------------------------------------------------------------------
# Weather Plugin
# ------------------------------------------------------------------------------------------------
#
# Weather information provided via API from https://www.openweathermap.org
#
# Create free API key @ https://home.openweathermap.org/api_keys
#
# For 3-Day Forecasts, add "Base Plan" @ https://home.openweathermap.org/subscriptions
# Requires credit card subscription with 1000 x free API calls per day.
# Maximum calls per day can be set to 1000 to avoid charges.
#
# ------------------------------------------------------------------------------------------------

# ------------------------------------------------------------------------------------------------


package require json
package require http 2
package require tls 1.7

# -- register command with Armour's command handler
set addcmd(weather) { weather 1 pub msg dcc }
set addcmd(w)       { weather 1 pub msg dcc }

# -- shortcut
proc weather:cmd:w {0 1 2 3 {4 ""} {5 ""}} { coroexec weather:cmd:weather $0 $1 $2 $3 $4 $5 }
# -- cmd: weather
proc weather:cmd:weather {0 1 2 3 {4 ""} {5 ""}} {
    variable dbchans
    variable weatherLoop
    lassign [proc:setvars $0 $1 $2 $3 $4 $5] type stype target starget nick uh hand source chan arg 

    set cmd "weather"

    lassign [db:get id,user users curnick $nick] uid user
    set chan [userdb:get:chan $user $chan]; # -- predict chan when not given

    set cid [db:get id channels chan $chan]
    if {$cid eq ""} { set cid 1 }; # -- default to global chan when command used in an unregistered chan

    set ison [arm::db:get value settings setting "weather" cid $cid]
    if {$ison ne "on"} {
        # -- weather not enabled on chan
        debug 1 "\002cmd:cmd:weather:\002 weather not enabled on $chan. to enable, use: \002modchan $chan weather on\002"
        return;
    }

    # -- ensure user has required access for command
	set allowed [cfg:get weather:allow]; # -- who can use commands? (1-5)
                                         #        1: all channel users
									     #        2: only voiced, opped, and authed users
                                         #        3: only voiced when not secure mode, opped, and authed users
                        	             #        4: only opped and authed channel users
                                         #        5: only authed users with command access
    set allow 0
    if {$uid eq ""} { set authed 0 } else { set authed 1 }
    if {$allowed eq 0} { return; } \
    elseif {$allowed eq 1} { set allow 1 } \
	elseif {$allowed eq 2} { if {[isop $nick $chan] || [isvoice $nick $chan] || $authed} { set allow 1 } } \
    elseif {$allowed eq 3} { if {[isop $nick $chan] || ([isvoice $nick $chan] && [dict get $dbchans $cid mode] ne "secure") || $authed} { set allow 1 } } \
    elseif {$allowed eq 4} { if {[isop $nick $chan] || $authed} { set allow 1 } } \
    elseif {$allowed eq 5} { if {$authed} { set allow [userdb:isAllowed $nick $cmd $chan $type] } }
    if {[userdb:isIgnored $nick $cid]} { set allow 0 }; # -- check if user is ignored
    if {!$allow} { return; }; # -- client cannot use command

    set city [lrange $arg 0 end]
    if {$city eq "" && $uid eq ""} {
        reply $type $target "\002usage:\002 weather <city>"
        return;
    }
    set dbcity [join [db:get value settings setting city uid $uid]]
    if {$dbcity ne "" && $city eq ""} {
        set city $dbcity
    } elseif {$city eq "" && $dbcity eq ""} {
        reply $type $target "\002usage:\002 weather <city>"
        return;
    }
    if {[string is digit $city]} {
        reply $type $target "\002error:\002 city cannot be a ZIP code (too ambiguous)"
        return;
    }

    set cfgUnits [cfg:get weather:units $chan]
    if {$cfgUnits eq "both"} {
        set units "metric"
    } else {
        set units $cfgUnits
    }

    # -- use precision to one decimal place? (celsius temp, wind speed)
    if {[cfg:get weather:precise $chan]} { set decimals "%0.1f" } else { set decimals "%0.0f" }

    set api_key [cfg:get weather:key $chan]
    http::register https 443 [list ::tls::socket -autoservername true]
    set query [http::formatQuery q $city appid $api_key lang en units $units]

	if {[catch {http::geturl https://api.openweathermap.org/data/2.5/weather?$query} tok]} {
		debug 0 "\002cmd:cmd:weather:\002 socket error: $tok"
		return;
	}
	if {[http::status $tok] ne "ok"} {
		set status [http::status $tok]
		debug 0 "\002cmd:cmd:weather:\002 TCP error: $status"
		return;
	}
    set ncode [http::ncode $tok]
    if {![info exists weatherLoop]} { set weatherLoop 0 }; # -- loop counter
	if {$ncode ne 200} {
		set code [http::code $tok]
		http::cleanup $tok
		debug 0 "\002cmd:cmd:weather:\002 HTTP Error: $code"
        if {$ncode eq 404} {
            # -- city not found
            if {[regexp -- {^(.*)\s([A-Za-z]{2})$} $city -> loc iso] && $weatherLoop < 1} {
                # -- try reformat to "city, country"
                incr weatherLoop
                switch -- $type {
                    pub { arm:cmd:weather $0 $1 $2 $3 $4 "$loc, $iso" }
                    msg { arm:cmd:weather $0 $1 $2 $3 "$loc, $iso" }
                    dcc { arm:cmd:weather $0 $1 $2 "$loc, $iso" }
                }
            } else {
                set city [string totitle $city]
                reply $type $target "\002error:\002 city not found: $city"
            }
            
        } else {
            reply $type $target "\002error:\002 HTTP error: $code"
        }
		return;
	}
    set weatherLoop 0; # -- reset loop counter

	set data [http::data $tok]
    http::cleanup $tok
	set parse [::json::json2dict $data]

    set coord [dict get $parse coord]
    set lat [dict get $coord lat]
    set lon [dict get $coord lon]
    set sunrise [expr [join [dict get $parse sys sunrise]] + [join [dict get $parse timezone]]]
    set sunset [expr [join [dict get $parse sys sunset]] + [join [dict get $parse timezone]]]
	set sunrise [clock format $sunrise -format "%H:%M" -gmt 1]
	set sunset [clock format $sunset -format "%H:%M" -gmt 1]
    set city [join [dict get $parse name]]
	set country [join [dict get $parse sys country]]
    set timezone [join [dict get $parse timezone]]
    set current_time [expr {[clock seconds] + $timezone}]
    set weather [join [dict get $parse weather]]
    set weather_main [dict get $weather main]
    set description [dict get $weather description]
    set temp [string map {.0 ""} [format $decimals [join [dict get $parse main temp]]]]
    set temp_max [string map {.0 ""} [format $decimals [join [dict get $parse main temp_max]]]]
    set temp_maxF [format "%.0f" [expr ($temp_max * 9/5) + 32]]
    set feels_like [string map {.0 ""} [format $decimals [join [dict get $parse main feels_like]]]]
    set feels_likeF [format $decimals [expr ($feels_like * 9/5) + 32]]
	set humidity [join [dict get $parse main humidity]]
    set windspeed [string map {.0 ""} [format $decimals [join [dict get $parse wind speed]]]]
	set cloudcover [join [dict get $parse clouds all]]
	#set dt [duration [expr [unixtime] - [dict get $parse dt]]]; # -- time since last update
	set clouds [dict get [lindex [dict get $parse weather] 0] description]
    set code [dict get [lindex [dict get $parse weather] 0] id]
    set emoji [weather:emoji $code]

    if {$cfgUnits eq "metric"} {
        set basicReply "\002weather -\002 $city, $country: $emoji \002$temp\002°C (\002max:\002 ${temp_max}°C), \002$humidity\002% humidity, \002$windspeed\002 km/h wind,\
            \002feels like:\002 ${feels_like}°C, \002$cloudcover\002% cloud cover (\002$clouds\002). Sunrise: \002$sunrise\002 / Sunset: \002$sunset\002"
    } elseif {$cfgUnits eq "imperial"} {
        set basicReply "\002weather -\002 $city, $country: $emoji\ 002$temp\002°F (\002max:\002 ${temp_maxF}°F), \002$humidity\002% humidity, \002$windspeed\002 mph wind,\
            \002feels like:\002 ${feels_likeF}°F, \002$cloudcover\002% cloud cover (\002$clouds\002). Sunrise: \002$sunrise\002 / Sunset: \002$sunset\002"
    } elseif {$cfgUnits eq "both"} {
        set tempF [format "%.0f" [expr ($temp * 9/5) + 32]]
        set windspeedMph [format "%.0f" [expr $windspeed * 0.621371]]
        set basicReply "\002weather -\002 $city, $country: $emoji \002$temp\002°C (\002$tempF\002°F), \002max:\002 ${temp_max}°C (${temp_maxF}°F), \002$humidity\002% humidity,\
            \002$windspeed\002 km/h (\002$windspeedMph\002 mph) wind, \002feels like:\002 ${feels_like}°C / ${feels_likeF}°F, \002$cloudcover\002% cloud cover (\002$clouds\002). Sunrise: \002$sunrise\002 / Sunset: \002$sunset\002"
    }

    # -- fetch detailed forecast
    set url "https://api.openweathermap.org/data/3.0/onecall?lat=${lat}&lon=${lon}&exclude=minutely,hourly&appid=${api_key}&units=${units}"
    set response [::http::geturl $url]

    if {[::http::status $response] ne "ok"} {
        reply $type $target "\002error:\002 HTTP error: [http::ncode $response]"
    }

    set forecast_data [::http::data $response]
    set json_forecast [::json::json2dict $forecast_data]

    if {[dict exists $json_forecast cod]} {
        # -- just send the basic reply without forecast
        # -- account probably doesn't have billing plan for forecasts
        reply $type $target $basicReply
        #reply $type $target "\002error:\002 [dict get $json_forecast message]"
        return;
    }

    set daily_forecast [dict get $json_forecast daily]
    set forecast_msg ""

    for {set i 1} {$i <= 3} {incr i} {
        set day_forecast [lindex $daily_forecast $i]
        set day [clock format [dict get $day_forecast dt] -format "%a" -gmt 1]
        set day_weather [join [dict get $day_forecast weather]]
        set day_weather_main [dict get $day_weather main]
        set day_description [dict get $day_weather description]
        set day_emoji [weather:emoji [dict get $day_weather id]]
        set temp_min [string map {.0 ""} [format $decimals [dict get $day_forecast temp min]]]
        set temp_max [string map {.0 ""} [format $decimals [dict get $day_forecast temp max]]]

        if {$cfgUnits eq "metric"} {
            append forecast_msg "$day: $day_emoji  (\002high:\002 ${temp_max}°C, \002low:\002 ${temp_min}°C) \002--\002 "
        } elseif {$cfgUnits eq "imperial"} {
            set temp_minF [format "%.0f" [expr ($temp_min * 9/5) + 32]]
            set temp_maxF [format "%.0f" [expr ($temp_max * 9/5) + 32]]
            append forecast_msg "\002$day:\002 $day_emoji (\002high:\002 ${temp_maxF}°F, \002low:\002 ${temp_minF}°F) \002--\002 "
        } elseif {$cfgUnits eq "both"} {
            set temp_minF [format "%.0f" [expr ($temp_min * 9/5) + 32]]
            set temp_maxF [format "%.0f" [expr ($temp_max * 9/5) + 32]]
            append forecast_msg "\002$day:\002 $day_emoji (\002high:\002 ${temp_max}°C / ${temp_maxF}°F, \002low:\002 ${temp_min}°C / ${temp_minF}°F) \002--\002 "
        }
    }
    set forecast_msg [string trimright $forecast_msg " \002--\002 "]

    if {$cfgUnits eq "metric"} {
        set detailedReply "\002weather:\002 $city, $country: $emoji \002${temp}\002°C (\002max:\002 ${temp_max}°C), \002$humidity\002% humidity, \
            \002$windspeed\002 km/h wind, \002feels like:\002 ${feels_like}°C, \002$cloudcover\002% cloud cover (\002$clouds\002) -- \
            \002time:\002 [clock format $current_time -format "%H:%M" -gmt 1] -- \002sunrise:\002 $sunrise -- \
            \002sunset:\002 $sunset -- \002forecast:\002 $forecast_msg"

    } elseif {$cfgUnits eq "imperial"} {
        set temp [format $decimals [expr ($temp * 9/5) + 32]]
        set windspeed [format "%.0f" [expr $windspeed * 0.621371]]
        set detailedReply "\002weather:\002 $city, $country: $emoji \002${temp}\002°F (\002max:\002 ${temp_maxF}°F), \002$humidity\002% humidity, \
            \002$windspeed\002 mph wind, \002feels like:\002 ${feels_likeF}°F, \002$cloudcover\002% cloud cover (\002$clouds\002) -- \
            \002time:\002 [clock format $current_time -format "%H:%M" -gmt 1] -- \002sunrise:\002 $sunrise -- \
            \002sunset:\002 $sunset -- \002forecast:\002 $forecast_msg"

    } elseif {$cfgUnits eq "both"} {
        set tempF [format "%.0f" [expr ($temp * 9/5) + 32]]
        set windspeedMph [format "%.0f" [expr $windspeed * 0.621371]]
        set detailedReply "\002weather:\002 $city, $country: $emoji \002${temp}\002°C (\002${tempF}\002°F), \002max:\002 ${temp_max}°C (${temp_maxF}°F), \002$humidity\002% humidity,\
            \002$windspeed\002 km/h (\002${windspeedMph}\002 mph) wind, \002feels like:\002 ${feels_like}°C / ${feels_likeF}°F, \002$cloudcover\002% cloud cover (\002$clouds\002) --\
            \002time:\002 [clock format $current_time -format "%H:%M" -gmt 1] -- \002sunrise:\002 $sunrise --\
            \002sunset:\002 $sunset -- \002forecast:\002 $forecast_msg"
    }

    reply $type $target $detailedReply; # -- send the reply
}

# -- return weather emojis by openweathermap.org code
proc weather:emoji {code} {
    set weatherEmojis {
        "200" "\U1F329"  "201" "\U1F329"  "202" "\U1F329"
        "210" "\U1F329"  "211" "\U1F329"  "212" "\U1F329"
        "221" "\U1F329"  "230" "\U1F329"  "231" "\U1F329"
        "232" "\U1F329"  "300" "\U1F327"  "301" "\U1F327"
        "302" "\U1F327"  "310" "\U1F327"  "311" "\U1F327"
        "312" "\U1F327"  "313" "\U1F327"  "314" "\U1F327"
        "321" "\U1F327"  "500" "\U1F326"  "501" "\U1F326"
        "502" "\U1F326"  "503" "\U1F326"  "504" "\U1F326"
        "511" "\U1F327"  "520" "\U1F326"  "521" "\U1F326"
        "522" "\U1F326"  "531" "\U1F326"  "600" "\U1F328"
        "601" "\U1F328"  "602" "\U1F328"  "611" "\U1F328"
        "612" "\U1F328"  "613" "\U1F328"  "615" "\U1F328"
        "616" "\U1F328"  "620" "\U1F328"  "621" "\U1F328"
        "622" "\U1F328"  "701" "\U1F32B"  "711" "\U1F32B"
        "721" "\U1F32B"  "731" "\U1F32B"  "741" "\U1F32B"
        "751" "\U1F32B"  "761" "\U1F32B"  "762" "\U1F32B"
        "771" "\U1F32C"  "781" "\U1F300"  "800" "\U1F31E"
        "801" "\U1F324"  "802" "\U2601"   "803" "\U1F325"
        "804" "\U1F325"
    }

    # -- return the emoji
    if {[dict exists $weatherEmojis $code]} {
        set emoji [dict get $weatherEmojis $code]
        return "$emoji"
    } else {
        return ""
    }
}

putlog "\[A\] Armour: loaded plugin: weather"

# ------------------------------------------------------------------------------------------------

# ------------------------------------------------------------------------------------------------
