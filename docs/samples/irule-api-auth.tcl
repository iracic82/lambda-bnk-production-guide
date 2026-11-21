when HTTP_REQUEST {
  set bnk_user "anonymous"
  set bnk_downgraded 0
  set bnk_clen 0
  set bnk_body ""
  set bnk_epoch 0
  catch { set bnk_epoch [table lookup -notouch -subtable "bnk_quota_ie-3f9a1c0b7d2e" epoch] }
  if { [regexp {(\d+)$} $bnk_epoch -> bnk_d] } { scan $bnk_d %d bnk_epoch } else { set bnk_epoch 0 }
  if { [string first "/bnk/" [HTTP::path]] == 0 } {
    if { !([HTTP::header value "X-BNK-Flush"] eq "flush-token-0123456789abcdef") } {
      HTTP::respond 403 content {{"error":"forbidden"}} "Content-Type" "application/json"
      return
    }
    if { [HTTP::path] eq "/bnk/flush" && [HTTP::method] eq "GET" } {
      set bnk_lines ""
      set bnk_me [clock clicks]
      set bnk_lock [expr { [table add -subtable "bnk_pending_ie-3f9a1c0b7d2e" lock $bnk_me 2] eq $bnk_me }]
      set bnk_tail 0; catch { set bnk_tail [table lookup -notouch -subtable "bnk_pending_ie-3f9a1c0b7d2e" tail] }
      if { [regexp {(\d+)$} $bnk_tail -> bnk_d] } { scan $bnk_d %d bnk_tail } else { set bnk_tail 0 }
      set bnk_head 0; catch { set bnk_head [table lookup -notouch -subtable "bnk_pending_ie-3f9a1c0b7d2e" head] }
      if { [regexp {(\d+)$} $bnk_head -> bnk_d] } { scan $bnk_d %d bnk_head } else { set bnk_head 0 }
      set bnk_n 0
      while { $bnk_lock && $bnk_head < $bnk_tail && $bnk_n < 50 } {
        incr bnk_head
        incr bnk_n
        set bnk_v [table lookup -notouch -subtable "bnk_pending_ie-3f9a1c0b7d2e" "r$bnk_head"]
        table delete -subtable "bnk_pending_ie-3f9a1c0b7d2e" "r$bnk_head"
        set bnk_i [string first "v1|" $bnk_v]
        if { $bnk_i >= 0 } {
          append bnk_lines [string range $bnk_v $bnk_i end] "\n"
        }
      }
      if { $bnk_n > 0 } {
        table incr -subtable "bnk_pending_ie-3f9a1c0b7d2e" head $bnk_n
        table timeout -subtable "bnk_pending_ie-3f9a1c0b7d2e" head indefinite
      }
      if { $bnk_lock } { table delete -subtable "bnk_pending_ie-3f9a1c0b7d2e" lock }
      if { $bnk_lines ne "" } {
        if { [catch {
          set bnk_c [connect -protocol TCP "10.1.10.11:5514"]
          send -timeout 2000 $bnk_c $bnk_lines
          close $bnk_c
        } bnk_err] } { log local0. "BNK usage flush failed: $bnk_err" }
      }
    }
    if { [HTTP::path] eq "/bnk/reset-quota" && [HTTP::method] eq "POST" } {
      table incr -subtable "bnk_quota_ie-3f9a1c0b7d2e" epoch
      table timeout -subtable "bnk_quota_ie-3f9a1c0b7d2e" epoch indefinite
    } elseif { [HTTP::path] ne "/bnk/flush" || [HTTP::method] ne "GET" } {
      HTTP::respond 404 content {{"error":"not found"}} "Content-Type" "application/json"
      return
    }
    HTTP::respond 204
    return
  }
  set authz [HTTP::header value "Authorization"]
  set bnk_ticketed 0
  if { $bnk_ticketed } {
  } elseif { $authz eq "" || [string first "Bearer " $authz] != 0 } {
    log local0. "Auth: no bearer token, 401"
    set bnk_line [join [list v1 ie-3f9a1c0b7d2e $bnk_user {} 0 0 0 auth_rejected {} 401 [clock clicks -milliseconds]] "|"]
    catch {
      set bnk_c [connect -protocol TCP "10.1.10.11:5514"]
      send -timeout 2000 $bnk_c "$bnk_line\n"
      close $bnk_c
    }
    HTTP::respond 401 content "{\"error\":\"unauthorized\",\"reason\":\"missing bearer token\",\"detail\":\"BNK rejected this request at the gateway before it reached the model\"}" "Content-Type" "application/json" "WWW-Authenticate" "Bearer" "X-Auth" "rejected"
    return
  } else {
    set token [string range $authz 7 end]
    set active "false"
    if { [regexp {^[A-Za-z0-9._~+/=-]+$} $token] } {
      if { [catch {
        set ibody "{\"token\":\"$token\"}"
        set ilen [string length $ibody]
        set ireq "POST /internal/v1/introspect HTTP/1.1\r\nHost: 10.96.12.34\r\nContent-Type: application/json\r\nContent-Length: $ilen\r\nConnection: close\r\n\r\n$ibody"
        set conn [connect -protocol TCP "10.96.12.34:8080"]
        send -timeout 3000 $conn $ireq
        set resp [recv -timeout 3000 $conn]
        close $conn
        if { [string match {*"active":true*} $resp] || [string match {*"active": true*} $resp] } {
          set active "true"
          regexp {\u0022sub\u0022\s*:\s*\u0022([^\u0022]+)\u0022} $resp -> bnk_user
        }
      } err] } { log local0. "Auth: introspection error, failing closed: $err" }
    }
    if { $active ne "true" } {
      log local0. "Auth: invalid token, 401"
      set bnk_line [join [list v1 ie-3f9a1c0b7d2e $bnk_user {} 0 0 0 auth_rejected {} 401 [clock clicks -milliseconds]] "|"]
      catch {
        set bnk_c [connect -protocol TCP "10.1.10.11:5514"]
        send -timeout 2000 $bnk_c "$bnk_line\n"
        close $bnk_c
      }
      HTTP::respond 401 content "{\"error\":\"unauthorized\",\"reason\":\"invalid or expired token\",\"detail\":\"BNK validated the token at the gateway and rejected it\"}" "Content-Type" "application/json" "X-Auth" "rejected"
      return
    }
  }
  if { ![regexp {^[A-Za-z0-9._@-]{1,64}$} $bnk_user] } { set bnk_user anonymous }
  if { [HTTP::header exists "Transfer-Encoding"] } {
    HTTP::respond 411 content {{"error":"Transfer-Encoding is not accepted; send a Content-Length"}} "Content-Type" "application/json"
    return
  }
  if { [HTTP::header exists "Content-Encoding"] && [string tolower [HTTP::header value "Content-Encoding"]] ne "identity" } {
    HTTP::respond 415 content {{"error":"compressed request bodies are not accepted"}} "Content-Type" "application/json"
    return
  }
  if { [HTTP::method] ne "GET" && [HTTP::method] ne "HEAD" } {
    if { ![HTTP::header exists "Content-Length"] } {
      HTTP::respond 411 content {{"error":"the request body must carry a Content-Length"}} "Content-Type" "application/json"
      return
    }
    set bnk_clen [HTTP::header value "Content-Length"]
    if { ![string is integer -strict $bnk_clen] || $bnk_clen > 1048576 } {
      HTTP::respond 413 content {{"error":"request body larger than 1 MiB"}} "Content-Type" "application/json"
      return
    }
    if { $bnk_clen > 0 } { HTTP::collect $bnk_clen }
  }
}
when HTTP_REQUEST_DATA {
  set bnk_body [HTTP::payload]
  if { [string length $bnk_body] > 0 && ![regexp {\u0022model\u0022\s*:} $bnk_body] } {
    regsub {^\s*\{} $bnk_body "\{\"model\":\"Qwen/Qwen2.5-7B-Instruct-AWQ\"," bnk_body
    HTTP::payload replace 0 [HTTP::payload length] $bnk_body
    HTTP::header replace "Content-Length" [HTTP::payload length]
  }
  if { [regexp {\u0022stream\u0022\s*:\s*true} $bnk_body] } {
    regsub {\}\s*$} $bnk_body ",\"stream_options\":\{\"include_usage\":true,\"continuous_usage_stats\":false\}\}" bnk_body
    HTTP::payload replace 0 [HTTP::payload length] $bnk_body
    HTTP::header replace "Content-Length" [HTTP::payload length]
  }
  HTTP::release
}
when HTTP_RESPONSE {
  HTTP::header insert X-Auth validated
  set bnk_status [HTTP::status]
  set bnk_member "[LB::server addr]:[LB::server port]"
  HTTP::header insert X-BNK-User $bnk_user
  HTTP::header insert X-BNK-Member $bnk_member
  set bnk_p 0
  set bnk_cp 0
  set bnk_t 0
  set bnk_m ""
  set bnk_parked 0
  set bnk_deltas 0
  set bnk_tail ""
  set bnk_stream [expr { [string first "event-stream" [HTTP::header value "Content-Type"]] >= 0 }]
  set bnk_chunked $bnk_stream
  if { $bnk_chunked } {
    HTTP::collect 1
  } elseif { [HTTP::header exists "Content-Length"] } {
    set bnk_rlen [HTTP::header value "Content-Length"]
    if { [string is integer -strict $bnk_rlen] && $bnk_rlen > 0 && $bnk_rlen <= 131072 } {
      HTTP::collect $bnk_rlen
    }
  } else {
    HTTP::collect 131072
  }
}
when HTTP_RESPONSE_DATA {
  if { [catch {
    if { $bnk_chunked } {
      set bnk_rb $bnk_tail
      append bnk_rb [HTTP::payload]
      incr bnk_deltas [regexp -all {\u0022delta\u0022\s*:\s*\{\s*\u0022} [HTTP::payload]]
      set bnk_tail [string range $bnk_rb end-1023 end]
      set bnk_done [regexp {\ndata: ?\[DONE\]\s*(\r?\n|$)} $bnk_rb]
      HTTP::release
      if { !$bnk_done } { HTTP::collect 1 }
    } else {
      set bnk_rb [HTTP::payload]
      set bnk_done 1
      if { $bnk_stream } {
        set bnk_deltas [regexp -all {\u0022delta\u0022\s*:\s*\{\s*\u0022} $bnk_rb]
      }
    }
    set bnk_i [string last {"prompt_tokens"} $bnk_rb]
    if { $bnk_i >= 0 && [regexp {"prompt_tokens"\s*:\s*(\d+)} [string range $bnk_rb $bnk_i end] -> bnk_v] && $bnk_v > $bnk_p } { set bnk_p $bnk_v }
    set bnk_i [string last {"completion_tokens"} $bnk_rb]
    if { $bnk_i >= 0 && [regexp {"completion_tokens"\s*:\s*(\d+)} [string range $bnk_rb $bnk_i end] -> bnk_v] && $bnk_v > $bnk_cp } { set bnk_cp $bnk_v }
    set bnk_i [string last {"total_tokens"} $bnk_rb]
    if { $bnk_i >= 0 && [regexp {"total_tokens"\s*:\s*(\d+)} [string range $bnk_rb $bnk_i end] -> bnk_v] && $bnk_v > $bnk_t } { set bnk_t $bnk_v }
    regexp {\u0022model\u0022\s*:\s*\u0022([A-Za-z0-9._/:-]{1,128})\u0022} $bnk_rb -> bnk_m
    if { $bnk_done && !$bnk_parked } {
      set bnk_parked 1
      if { $bnk_stream && $bnk_t == 0 && $bnk_deltas > 0 } {
        set bnk_cp $bnk_deltas
        set bnk_t [expr { $bnk_p + $bnk_deltas }]
      }
      if { $bnk_stream && $bnk_t < 1 && $bnk_status < 400 } { set bnk_t 1 }
      set bnk_outcome "served"
      if { $bnk_status >= 400 } {
        set bnk_outcome "error"
      } elseif { $bnk_downgraded } {
        set bnk_outcome "downgraded"
      }
      set bnk_line [join [list v1 ie-3f9a1c0b7d2e $bnk_user $bnk_m $bnk_p $bnk_cp $bnk_t $bnk_outcome $bnk_member $bnk_status [clock clicks -milliseconds]] "|"]
      set bnk_seq [table incr -subtable "bnk_pending_ie-3f9a1c0b7d2e" tail]
      table timeout -subtable "bnk_pending_ie-3f9a1c0b7d2e" tail indefinite
      if { [regexp {(\d+)$} $bnk_seq -> bnk_d] } { scan $bnk_d %d bnk_seq }
      table set -subtable "bnk_pending_ie-3f9a1c0b7d2e" "r$bnk_seq" $bnk_line 600 600
      if { $bnk_t > 0 } {
        table incr -subtable "bnk_quota_ie-3f9a1c0b7d2e" "$bnk_epoch:$bnk_user" $bnk_t
        table timeout -subtable "bnk_quota_ie-3f9a1c0b7d2e" "$bnk_epoch:$bnk_user" indefinite
      }
    }
  } bnk_err] } { log local0. "BNK metering failed: $bnk_err" }
}
when CLIENT_CLOSED {
  if { [info exists bnk_parked] && !$bnk_parked } {
    if { [catch {
      set bnk_parked 1
      if { $bnk_t == 0 } {
        set bnk_cp $bnk_deltas
        set bnk_t [expr { $bnk_p + $bnk_deltas }]
      }
      if { $bnk_t < 1 } { set bnk_t 1 }
      set bnk_outcome "served"
      if { $bnk_downgraded } { set bnk_outcome "downgraded" }
      set bnk_line [join [list v1 ie-3f9a1c0b7d2e $bnk_user $bnk_m $bnk_p $bnk_cp $bnk_t $bnk_outcome $bnk_member $bnk_status [clock clicks -milliseconds]] "|"]
      set bnk_seq [table incr -subtable "bnk_pending_ie-3f9a1c0b7d2e" tail]
      table timeout -subtable "bnk_pending_ie-3f9a1c0b7d2e" tail indefinite
      if { [regexp {(\d+)$} $bnk_seq -> bnk_d] } { scan $bnk_d %d bnk_seq }
      table set -subtable "bnk_pending_ie-3f9a1c0b7d2e" "r$bnk_seq" $bnk_line 600 600
      table incr -subtable "bnk_quota_ie-3f9a1c0b7d2e" "$bnk_epoch:$bnk_user" $bnk_t
      table timeout -subtable "bnk_quota_ie-3f9a1c0b7d2e" "$bnk_epoch:$bnk_user" indefinite
    } bnk_err] } { log local0. "BNK metering on close failed: $bnk_err" }
  }
}
