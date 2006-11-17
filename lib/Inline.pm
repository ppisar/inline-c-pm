package Inline;

use strict;
require 5.005;
$Inline::VERSION = '0.45';

use Inline::denter;
use Config;
use Carp;
use Cwd qw(abs_path cwd);
use File::Spec;
use File::Spec::Unix;

my %CONFIG = ();
my @DATA_OBJS = ();
my $INIT = 0;
my $version_requested = 0;
my $version_printed = 0;
my $untaint = 0;
my $safemode = 0;
my $languages = undef;

my %shortcuts = (
   NOCLEAN =>      [CLEAN_AFTER_BUILD => 0],
   CLEAN =>        [CLEAN_BUILD_AREA => 1],
   FORCE =>        [FORCE_BUILD => 1],
   INFO =>         [PRINT_INFO => 1],
   VERSION =>      [PRINT_VERSION => 1],
   REPORTBUG =>    [REPORTBUG => 1],
   UNTAINT =>      [UNTAINT => 1],
   SAFE =>         [SAFEMODE => 1],
   UNSAFE =>       [SAFEMODE => 0],
   GLOBAL =>       [GLOBAL_LOAD => 1],
   NOISY =>        [BUILD_NOISY => 1],
   TIMERS =>       [BUILD_TIMERS => 1],
   NOWARN =>       [WARNINGS => 0],
   _INSTALL_ =>    [_INSTALL_ => 1],
   SITE_INSTALL => undef,  # No longer supported.
);

my $default_config = {
   NAME => '',
   AUTONAME => -1,
   VERSION => '',
   DIRECTORY => '',
   WITH => [],
   USING => [],

   CLEAN_AFTER_BUILD => 1,
   CLEAN_BUILD_AREA => 0,
   FORCE_BUILD => 0,
   PRINT_INFO => 0,
   PRINT_VERSION => 0,
   REPORTBUG => 0,
   UNTAINT => 0,
   SAFEMODE => -1,
   GLOBAL_LOAD => 0,
   BUILD_NOISY => 0,
   BUILD_TIMERS => 0,
   WARNINGS => 1,
   _INSTALL_ => 0,
};

sub UNTAINT {$untaint}
sub SAFEMODE {$safemode}

#==============================================================================
# This is where everything starts.
#==============================================================================
sub import {
    local ($/, $") = ("\n", ' '); local ($\, $,);

    my $o;
    my ($pkg, $script) = caller;
    # Not sure what this is for. Let's see what breaks.
    # $pkg =~ s/^.*[\/\\]//; 
    my $class = shift;
    if ($class ne 'Inline') {
	croak M01_usage_use($class) if $class =~ /^Inline::/;
	croak M02_usage();
    }

    $CONFIG{$pkg}{template} ||= $default_config;

    return unless @_;
    &create_config_file(), return 1 if $_[0] eq '_CONFIG_';
    goto &maker_utils if $_[0] =~ /^(install|makedist|makeppd)$/i;

    my $control = shift;

    if ($control eq 'with') {
	return handle_with($pkg, @_);
    }
    elsif ($control eq 'Config') {
	return handle_global_config($pkg, @_);
    }
    elsif (exists $shortcuts{uc($control)}) {
	handle_shortcuts($pkg, $control, @_);
	$version_requested = $CONFIG{$pkg}{template}{PRINT_VERSION};
	return;
    }
    elsif ($control =~ /^\S+$/ and $control !~ /\n/) {
	my $language_id = $control;
	my $option = shift || '';
	my @config = @_;
	my $next = 0;
	for (@config) {
	    next if $next++ % 2;
	    croak M02_usage() if /[\s\n]/;
	}
	$o = bless {}, $class;
	$o->{INLINE}{version} = $Inline::VERSION;
	$o->{API}{pkg} = $pkg;
	$o->{API}{script} = $script;
	$o->{API}{language_id} = $language_id;
	if ($option =~ /^(FILE|BELOW)$/ or
	    not $option and
            defined $INC{File::Spec::Unix->catfile('Inline','Files.pm')} and
	    Inline::Files::get_filename($pkg)
	   ) {
	    $o->read_inline_file;
	    $o->{CONFIG} = handle_language_config(@config);
	}
	elsif ($option eq 'DATA' or not $option) {
	    $o->{CONFIG} = handle_language_config(@config);
	    push @DATA_OBJS, $o;
	    return;
	}
	elsif ($option eq 'Config') {
	    $CONFIG{$pkg}{$language_id} = handle_language_config(@config);
	    return;
	}
	else {
	    $o->receive_code($option);
	    $o->{CONFIG} = handle_language_config(@config);
	}
    }
    else {
	croak M02_usage();
    }
    $o->glue;
}

#==============================================================================
# Run time version of import (public method)
#==============================================================================
sub bind {
    local ($/, $") = ("\n", ' '); local ($\, $,);

    my ($code, @config);
    my $o;
    my ($pkg, $script) = caller;
    my $class = shift;
    croak M03_usage_bind() unless $class eq 'Inline';

    $CONFIG{$pkg}{template} ||= $default_config;

    my $language_id = shift or croak M03_usage_bind();
    croak M03_usage_bind()
      unless ($language_id =~ /^\S+$/ and $language_id !~ /\n/);
    $code = shift or croak M03_usage_bind();
    @config = @_;
	
    my $next = 0;
    for (@config) {
	next if $next++ % 2;
	croak M03_usage_bind() if /[\s\n]/;
    }
    $o = bless {}, $class;
    $o->{INLINE}{version} = $Inline::VERSION;
    $o->{API}{pkg} = $pkg;
    $o->{API}{script} = $script;
    $o->{API}{language_id} = $language_id;
    $o->receive_code($code);
    $o->{CONFIG} = handle_language_config(@config);

    $o->glue;
}

#==============================================================================
# Process delayed objects that don't have source code yet.
#==============================================================================
# This code is an ugly hack because of the fact that you can't use an 
# INIT block at "run-time proper". So we kill the warning for 5.6+ users
# and tell them to use a Inline->init() call if they run into problems. (rare)
my $lexwarn = ($] >= 5.006) ? 'no warnings;' : '';

eval <<END;
$lexwarn
\$INIT = \$INIT; # Needed by Sarathy's patch.
sub INIT {
    \$INIT++;
    &init;
}
END

sub init {
    local ($/, $") = ("\n", ' '); local ($\, $,);

    while (my $o = shift(@DATA_OBJS)) {
	$o->read_DATA;
	$o->glue;
    }
}

sub END {
    warn M51_unused_DATA() if @DATA_OBJS;
    print_version() if $version_requested && not $version_printed;
}

#==============================================================================
# Print a small report about the version of Inline
#==============================================================================
sub print_version {
    return if $version_printed++;
    print STDERR <<END;

    You are using Inline.pm version $Inline::VERSION

END
}

#==============================================================================
# Compile the source if needed and then dynaload the object
#==============================================================================
sub glue {
    my $o = shift;
    my ($pkg, $language_id) = @{$o->{API}}{qw(pkg language_id)};
    my @config = (%{$CONFIG{$pkg}{template}},
		  %{$CONFIG{$pkg}{$language_id} || {}},
		  %{$o->{CONFIG} || {}},
		 );
    @config = $o->check_config(@config);
    $o->fold_options;

    $o->check_installed;
    $o->env_untaint if UNTAINT;
    if (not $o->{INLINE}{object_ready}) {
	$o->check_config_file;                # Final DIRECTORY set here.
	push @config, $o->with_configs;
	my $language = $o->{API}{language};
	croak M04_error_nocode($language_id) unless $o->{API}{code};
	$o->check_module;
    }
    $o->env_untaint if UNTAINT;
    $o->obj_untaint if UNTAINT;
    print_version() if $version_requested;
    $o->reportbug() if $o->{CONFIG}{REPORTBUG};
    if (not $o->{INLINE}{object_ready}
	or $o->{CONFIG}{PRINT_INFO}
       ) {
	eval "require $o->{INLINE}{ILSM_module}";
	croak M05_error_eval('glue', $@) if $@;
        $o->push_overrides;
	bless $o, $o->{INLINE}{ILSM_module};    
	$o->validate(@config);
    }
    else {
	$o->{CONFIG} = {(%{$o->{CONFIG}}, @config)};
    }
    $o->print_info if $o->{CONFIG}{PRINT_INFO};
    unless ($o->{INLINE}{object_ready} or
	    not length $o->{INLINE}{ILSM_suffix}) {
	$o->build();
	$o->write_inl_file() unless $o->{CONFIG}{_INSTALL_};
    }
    if ($o->{INLINE}{ILSM_suffix} ne 'so' and
	$o->{INLINE}{ILSM_suffix} ne 'dll' and
	$o->{INLINE}{ILSM_suffix} ne 'bundle' and
	ref($o) eq 'Inline'
       ) {
	eval "require $o->{INLINE}{ILSM_module}";
	croak M05_error_eval('glue', $@) if $@;
        $o->push_overrides;
	bless $o, $o->{INLINE}{ILSM_module};
	$o->validate(@config);
    }
    $o->load;
    $o->pop_overrides;
}

#==============================================================================
# Set up the USING overrides
#==============================================================================
sub push_overrides {
    my ($o) = @_;
    my ($language_id) = $o->{API}{language_id};
    my ($ilsm) = $o->{INLINE}{ILSM_module};
    for (@{$o->{CONFIG}{USING}}) {
        my $using_module = /^::/
                           ? "Inline::$language_id$_"
                           : /::/
                             ? $_
                             : "Inline::${language_id}::$_";
        eval "require $using_module";
        croak "Invalid module '$using_module' in USING list:\n$@" if $@;
        my $register;
        eval "\$register = $using_module->register";
        croak "Invalid module '$using_module' in USING list:\n$@" if $@;
        for my $override (@{$register->{overrides}}) {
            no strict 'refs';
            next if defined $o->{OVERRIDDEN}{$ilsm . "::$override"};
            $o->{OVERRIDDEN}{$ilsm . "::$override"} =
              \&{$ilsm . "::$override"};
            *{$ilsm . "::$override"} =
              *{$using_module . "::$override"};
        }
    }
}
        
#==============================================================================
# Restore the modules original methods
#==============================================================================
sub pop_overrides {
    my ($o) = @_;
    for my $override (keys %{$o->{OVERRIDDEN}}) {
        no strict 'refs';
        *{$override} = $o->{OVERRIDDEN}{$override};
    }
    delete $o->{OVERRIDDEN};
}

#==============================================================================
# Get source from the DATA filehandle
#==============================================================================
my (%DATA, %DATA_read);
sub read_DATA {
    require Socket;
    my ($marker, $marker_tag);
    my $o = shift;
    my ($pkg, $language_id) = @{$o->{API}}{qw(pkg language_id)};
    unless ($DATA_read{$pkg}++) {
	no strict 'refs';
	*Inline::DATA = *{$pkg . '::DATA'};
	local ($/);
	my ($CR, $LF) = (&Socket::CR, &Socket::LF);
	(my $data = <Inline::DATA>) =~ s/$CR?$LF/\n/g;
	@{$DATA{$pkg}} = split /(?m)(__\S+?__\n)/, $data;
	shift @{$DATA{$pkg}} unless ($ {$DATA{$pkg}}[0] || '') =~ /__\S+?__\n/;
    }
    ($marker, $o->{API}{code}) = splice @{$DATA{$pkg}}, 0, 2;
    croak M08_no_DATA_source_code($language_id)
      unless defined $marker;
    ($marker_tag = $marker) =~ s/__(\S+?)__\n/$1/;
    croak M09_marker_mismatch($marker, $language_id)
      unless $marker_tag eq $language_id;
}

#==============================================================================
# Validate and store the non language-specific config options
#==============================================================================
sub check_config {
    my $o = shift;
    my @others;
    while (@_) {
	my ($key, $value) = (shift, shift);
	if (defined $default_config->{$key}) {
	    if ($key =~ /^(WITH|USING)$/) {
		croak M10_usage_WITH_USING() 
                  if (ref $value and ref $value ne 'ARRAY');
		$value = [$value] unless ref $value;
		$o->{CONFIG}{$key} = $value;
		next;
	    }
	    $o->{CONFIG}{$key} = $value, next if not $value;
	    if ($key eq 'DIRECTORY') {
		croak M11_usage_DIRECTORY($value) unless (-d $value);
		$value = abs_path($value);
	    }
	    elsif ($key eq 'NAME') {
		croak M12_usage_NAME($value) 
		  unless $value =~ /^[a-zA-Z_](\w|::)*$/;
	    }
	    elsif ($key eq 'VERSION') {
		croak M13_usage_VERSION($value) unless $value =~ /^\d\.\d\d*$/;
	    }
	    $o->{CONFIG}{$key} = $value;
	}
	else {
	    push @others, $key, $value;
	}
    }
    return (@others);
}

#==============================================================================
# Set option defaults based on current option settings.
#==============================================================================
sub fold_options {
    my $o = shift;
    $untaint = $o->{CONFIG}{UNTAINT} || 0;
    $safemode = (($o->{CONFIG}{SAFEMODE} == -1) ?
		 ($untaint ? 1 : 0) :
		 $o->{CONFIG}{SAFEMODE}
		);
    if (UNTAINT and
	SAFEMODE and
	not $o->{CONFIG}{DIRECTORY}) {
	croak M49_usage_unsafe(1) if ($< == 0 or $> == 0);
	warn M49_usage_unsafe(0) if $^W;
    }
    if ($o->{CONFIG}{AUTONAME} == -1) {
	$o->{CONFIG}{AUTONAME} = length($o->{CONFIG}{NAME}) ? 0 : 1;
    }
    $o->{API}{cleanup} = 
      ($o->{CONFIG}{CLEAN_AFTER_BUILD} and not $o->{CONFIG}{REPORTBUG});
}

#==============================================================================
# Check if Inline extension is preinstalled
#==============================================================================
sub check_installed {
    my $o = shift;
    $o->{INLINE}{object_ready} = 0;
    unless ($o->{API}{code} =~ /^[A-Fa-f0-9]{32}$/) {
	require Digest::MD5;
	$o->{INLINE}{md5} = Digest::MD5::md5_hex($o->{API}{code});
    }
    else {
	$o->{INLINE}{md5} = $o->{API}{code};
    }
    return if $o->{CONFIG}{_INSTALL_};
    return unless $o->{CONFIG}{VERSION};
    croak M26_error_version_without_name()
      unless $o->{CONFIG}{NAME};

    my @pkgparts = split(/::/, $o->{API}{pkg});
    my $realname = File::Spec->catfile(@pkgparts) . '.pm';
    my $realname_unix = File::Spec::Unix->catfile(@pkgparts) . '.pm';
    my $realpath = $INC{$realname_unix}
      or croak M27_module_not_indexed($realname_unix);

    my ($volume,$dir,$file) = File::Spec->splitpath($realpath);
    my @dirparts = File::Spec->splitdir($dir);
    pop @dirparts unless $dirparts[-1];
    push @dirparts, $file;
    my @endparts = splice(@dirparts, 0 - @pkgparts);
    
    $dirparts[-1] = 'arch'
      if $dirparts[-2] eq 'blib' && $dirparts[-1] eq 'lib';
    File::Spec->catfile(@endparts) eq $realname 
      or croak M28_error_grokking_path($realpath);
    $realpath = 
      File::Spec->catpath($volume,File::Spec->catdir(@dirparts),"");

    $o->{API}{version} = $o->{CONFIG}{VERSION};
    $o->{API}{module} = $o->{CONFIG}{NAME};
    my @modparts = split(/::/,$o->{API}{module});
    $o->{API}{modfname} = $modparts[-1];
    $o->{API}{modpname} = File::Spec->catdir(@modparts);

    my $suffix = $Config{dlext};
    my $obj = File::Spec->catfile($realpath,'auto',$o->{API}{modpname},
                                  "$o->{API}{modfname}.$suffix");
    croak M30_error_no_obj($o->{CONFIG}{NAME}, $o->{API}{pkg}, 
			   $realpath) unless -f $obj;

    @{$o->{CONFIG}}{qw( PRINT_INFO 
			REPORTBUG 
			FORCE_BUILD
			_INSTALL_
		      )} = (0, 0, 0, 0);

    $o->{install_lib} = $realpath;
    $o->{INLINE}{ILSM_type} = 'compiled';
    $o->{INLINE}{ILSM_module} = 'Inline::C';
    $o->{INLINE}{ILSM_suffix} = $suffix;
    $o->{INLINE}{object_ready} = 1;
}

#==============================================================================
# Dynamically load the object module
#==============================================================================
sub load {
    my $o = shift;

    if ($o->{CONFIG}{_INSTALL_}) {
	my $inline = "$o->{API}{modfname}.inl";
	open INLINE, "> $inline" 
	  or croak M24_open_for_output_failed($inline);
	print INLINE "*** AUTOGENERATED by Inline.pm ***\n\n";
	print INLINE "This file satisfies the make dependency for ";
	print INLINE "$o->{API}{modfname}.pm\n";
	close INLINE;
	return;
    }

    my ($pkg, $module) = @{$o->{API}}{qw(pkg module)};
    croak M42_usage_loader() unless $o->{INLINE}{ILSM_type} eq 'compiled';

    require DynaLoader;
    @Inline::ISA = qw(DynaLoader);

    my $global = $o->{CONFIG}{GLOBAL_LOAD} ? '0x01' : '0x00';
    my $version = $o->{API}{version} || '0.00';

    eval <<END;
	package $pkg;
	push \@$ {pkg}::ISA, qw($module)
          unless \$module eq "$pkg";
        local \$$ {module}::VERSION = '$version';

	package $module;
	push \@$ {module}::ISA, qw(Exporter DynaLoader);
        sub dl_load_flags { $global } 
	${module}::->bootstrap;
END
    croak M43_error_bootstrap($module, $@) if $@;
}

#==============================================================================
# Process the config options that apply to all Inline sections
#==============================================================================
sub handle_global_config {
    my $pkg = shift;
    while (@_) {
	my ($key, $value) = (shift, shift);
	croak M02_usage() if $key =~ /[\s\n]/;
	$key = $value if $key =~ /^(ENABLE|DISABLE)$/;
	croak M47_invalid_config_option($key)
	  unless defined $default_config->{$key};
	if ($key eq 'ENABLE') {
	    $CONFIG{$pkg}{template}{$value} = 1;
	}
	elsif ($key eq 'DISABLE') {
	    $CONFIG{$pkg}{template}{$value} = 0;
	}
	else {
	    $CONFIG{$pkg}{template}{$key} = $value;
	}
    }
}

#==============================================================================
# Process the config options that apply to a particular language
#==============================================================================
sub handle_language_config {
    my @values;
    while (@_) {
	my ($key, $value) = (shift, shift);
	croak M02_usage() if $key =~ /[\s\n]/;
	if ($key eq 'ENABLE') {
	    push @values, $value, 1;
	}
	elsif ($key eq 'DISABLE') {
	    push @values, $value, 0;
	}
	else {
	    push @values, $key, $value;
	}
    }
    return {@values};
}

#==============================================================================
# Validate and store shortcut config options
#==============================================================================
sub handle_shortcuts {
    my $pkg = shift;

    for my $option (@_) {
	my $OPTION = uc($option);
	if ($OPTION eq 'SITE_INSTALL') {
	    croak M58_site_install();
	}
	elsif ($shortcuts{$OPTION}) {
	    my ($method, $arg) = @{$shortcuts{$OPTION}};
	    $CONFIG{$pkg}{template}{$method} = $arg;
	}
	else {
	    croak M48_usage_shortcuts($option);
	}
    }    
}

#==============================================================================
# Process the with command
#==============================================================================
sub handle_with {
    my $pkg = shift;
    croak M45_usage_with() unless @_;
    for (@_) {
	croak M02_usage() unless /^[\w:]+$/;
	eval "require $_;";
	croak M46_usage_with_bad($_) . $@ if $@;
	push @{$CONFIG{$pkg}{template}{WITH}}, $_;
    }
}

#==============================================================================
# Perform cleanup duties
#==============================================================================
sub DESTROY {
    my $o = shift;
    $o->clean_build if $o->{CONFIG}{CLEAN_BUILD_AREA};
}

#==============================================================================
# Get the source code
#==============================================================================
sub receive_code {
    my $o = shift;
    my $code = shift;
    
    croak M02_usage() unless (defined $code and $code);

    if (ref $code eq 'CODE') {
	$o->{API}{code} = &$code;
    }
    elsif (ref $code eq 'ARRAY') {
        $o->{API}{code} = join '', @$code;
    }
    elsif ($code =~ m|[/\\:]| and
           $code =~ m|^[/\\:\w.\-\ \$\[\]<>]+$|) {
	if (-f $code) {
	    local ($/, *CODE);
	    open CODE, "< $code" or croak M06_code_file_failed_open($code);
	    $o->{API}{code} = <CODE>;
	}
	else {
	    croak M07_code_file_does_not_exist($code);
	}
    } 
    else {
	$o->{API}{code} = $code;
    }
}

#==============================================================================
# Get the source code from an Inline::Files filehandle
#==============================================================================
sub read_inline_file {
    my $o = shift;
    my ($lang, $pkg) = @{$o->{API}}{qw(language_id pkg)};
    my $langfile = uc($lang);
    croak M59_bad_inline_file($lang) unless $langfile =~ /^[A-Z]\w*$/;
    croak M60_no_inline_files() 
      unless (defined $INC{File::Spec::Unix->catfile("Inline","Files.pm")} and
	      $Inline::Files::VERSION =~ /^\d\.\d\d$/ and
	      $Inline::Files::VERSION ge '0.51');
    croak M61_not_parsed() unless $lang = Inline::Files::get_filename($pkg);
    {
	no strict 'refs';
	local $/;
	$Inline::FILE = \*{"${pkg}::$langfile"};
#	open $Inline::FILE;
	$o->{API}{code} = <$Inline::FILE>;
#	close $Inline::FILE;
    }
}

#==============================================================================
# Read the cached config file from the Inline directory. This will indicate
# whether the Language code is valid or not.
#==============================================================================
sub check_config_file {
    my ($DIRECTORY, %config);
    my $o = shift;

    croak M14_usage_Config() if defined %main::Inline::Config::;
    croak M63_no_source($o->{API}{pkg}) 
      if $o->{INLINE}{md5} eq $o->{API}{code};

    # First make sure we have the DIRECTORY
    if ($o->{CONFIG}{_INSTALL_}) {
	croak M15_usage_install_directory()
	  if $o->{CONFIG}{DIRECTORY};
	my $cwd = Cwd::cwd();
        $DIRECTORY = 
          $o->{INLINE}{DIRECTORY} = File::Spec->catdir($cwd,"_Inline");
	if (not -d $DIRECTORY) {
	    _mkdir($DIRECTORY, 0777)
	      or croak M16_DIRECTORY_mkdir_failed($DIRECTORY);
	}
    }
    else {
	$DIRECTORY = $o->{INLINE}{DIRECTORY} =
	  $o->{CONFIG}{DIRECTORY} || $o->find_temp_dir;
    }

    $o->create_config_file($DIRECTORY) 
      if not -e File::Spec->catfile($DIRECTORY,"config");

    open CONFIG, "< ".File::Spec->catfile($DIRECTORY,"config")
      or croak M17_config_open_failed($DIRECTORY);
    my $config = join '', <CONFIG>;
    close CONFIG;

    croak M62_invalid_config_file(File::Spec->catfile($DIRECTORY,"config"))
      unless $config =~ /^version :/;
    ($config) = $config =~ /(.*)/s if UNTAINT;

    %config = Inline::denter->new()->undent($config);
    $languages = $config{languages};

    croak M18_error_old_version($config{version}, $DIRECTORY)
	unless (defined $config{version} and
                $config{version} =~ /TRIAL/ or
		$config{version} >= 0.40);
    croak M19_usage_language($o->{API}{language_id}, $DIRECTORY)
      unless defined $config{languages}->{$o->{API}{language_id}};
    $o->{API}{language} = $config{languages}->{$o->{API}{language_id}};
    if ($o->{API}{language} ne $o->{API}{language_id}) {
	if (defined $o->{$o->{API}{language_id}}) {
	    $o->{$o->{API}{language}} = $o->{$o->{API}{language_id}};
	    delete $o->{$o->{API}{language_id}};
	}
    }

    $o->{INLINE}{ILSM_type} = $config{types}->{$o->{API}{language}};
    $o->{INLINE}{ILSM_module} = $config{modules}->{$o->{API}{language}};
    $o->{INLINE}{ILSM_suffix} = $config{suffixes}->{$o->{API}{language}};
}

#==============================================================================
# Auto-detect installed Inline language support modules
#==============================================================================
sub create_config_file {
    my ($o, $dir) = @_;

    # This subroutine actually fires off another instance of perl.
    # with arguments that make this routine get called again.
    # That way the queried modules don't stay loaded.
    if (defined $o) {
	($dir) = $dir =~ /(.*)/s if UNTAINT;
	my $perl = $Config{perlpath};
        $perl = $^X unless -f $perl;
	($perl) = $perl =~ /(.*)/s if UNTAINT;
	local $ENV{PERL5LIB} if defined $ENV{PERL5LIB};
	local $ENV{PERL5OPT} if defined $ENV{PERL5OPT};
	my $inline = $INC{'Inline.pm'};
    $inline ||= File::Spec->curdir();
    my($v,$d,$f) = File::Spec->splitpath($inline);
    $f = "" if $f eq 'Inline.pm';
    $inline = File::Spec->catpath($v,$d,$f);
    my @INC = map { "-I$_" }
               ($inline,
                grep {(-d File::Spec->catdir($_,"Inline") or -d File::Spec->>catdir($_,"auto","Inline"))} @INC);
    system( $perl, @INC, "-MInline=_CONFIG_", "-e1", "$dir"
	  and croak M20_config_creation_failed($dir);
	return;
    }

    my ($lib, $mod, $register, %checked,
	%languages, %types, %modules, %suffixes);
  LIB:
    for my $lib (@INC) {
        next unless -d File::Spec->catdir($lib,"Inline");
        opendir LIB, File::Spec->catdir($lib,"Inline") 
          or warn(M21_opendir_failed(File::Spec->catdir($lib,"Inline"))), next;
	while ($mod = readdir(LIB)) {
	    next unless $mod =~ /\.pm$/;
	    $mod =~ s/\.pm$//;
	    next LIB if ($checked{$mod}++);
	    if ($mod eq 'Config') {     # Skip Inline::Config
		warn M14_usage_Config();
		next;
	    }
	    next if $mod =~ /^(MakeMaker|denter|messages)$/;
	    eval "require Inline::$mod;";
            warn($@), next if $@;
	    eval "\$register=&Inline::${mod}::register";
	    next if $@;
	    my $language = ($register->{language}) 
	      or warn(M22_usage_register($mod)), next;
	    for (@{$register->{aliases}}) {
		warn(M23_usage_alias_used($mod, $_, $languages{$_})), next
		  if defined $languages{$_};
		$languages{$_} = $language;
	    }
	    $languages{$language} = $language;
	    $types{$language} = $register->{type};
	    $modules{$language} = "Inline::$mod";
	    $suffixes{$language} = $register->{suffix};
	}
	closedir LIB;
    }

    my $file = File::Spec->catfile($ARGV[0],"config");
    open CONFIG, "> $file" or croak M24_open_for_output_failed($file);
    print CONFIG Inline::denter->new()
      ->indent(*version => $Inline::VERSION,
	       *languages => \%languages,
	       *types => \%types,
	       *modules => \%modules,
	       *suffixes => \%suffixes,
	      );
    close CONFIG;
    exit 0;
}

#==============================================================================
# Check to see if code has already been compiled
#==============================================================================
sub check_module {
    my ($module, $module2);
    my $o = shift;
    return $o->install if $o->{CONFIG}{_INSTALL_};

    if ($o->{CONFIG}{NAME}) {
	$module = $o->{CONFIG}{NAME};
    }
    elsif ($o->{API}{pkg} eq 'main') {
	$module = $o->{API}{script};
        my($v,$d,$file) = File::Spec->splitpath($module);
        $module = $file;
	$module =~ s|\W|_|g;
	$module =~ s|^_+||;
	$module =~ s|_+$||;
	$module = 'FOO' if $module =~ /^_*$/;
	$module = "_$module" if $module =~ /^\d/;
    }
    else {
	$module = $o->{API}{pkg};
    }

    $o->{API}{suffix} = $o->{INLINE}{ILSM_suffix};
    $o->{API}{directory} = $o->{INLINE}{DIRECTORY};

    my $auto_level = 2;
    while ($auto_level <= 5) {
	if ($o->{CONFIG}{AUTONAME}) {
	    $module2 = 
	      $module . '_' . substr($o->{INLINE}{md5}, 0, 2**$auto_level);
	    $auto_level++;
	} else {
	    $module2 = $module;
	    $auto_level = 6; # Don't loop on non-autoname objects
	}
	$o->{API}{module} = $module2;
	my @modparts = split /::/, $module2;
	$o->{API}{modfname} = $modparts[-1];
        $o->{API}{modpname} = File::Spec->catdir(@modparts);
	$o->{API}{build_dir} = 
          File::Spec->catdir($o->{INLINE}{DIRECTORY},
                             'build',$o->{API}{modpname});
        $o->{API}{install_lib} = 
          File::Spec->catdir($o->{INLINE}{DIRECTORY}, 'lib');

        my $inl = File::Spec->catfile($o->{API}{install_lib},"auto",
                          $o->{API}{modpname},"$o->{API}{modfname}.inl");
        $o->{API}{location} =
          File::Spec->catfile($o->{API}{install_lib},"auto",$o->{API}{modpname},
                              "$o->{API}{modfname}.$o->{INLINE}{ILSM_suffix}");
	last unless -f $inl;
	my %inl;
	{   local ($/, *INL);
	    open INL, $inl or croak M31_inline_open_failed($inl);
	    %inl = Inline::denter->new()->undent(<INL>);
	}
	next unless ($o->{INLINE}{md5} eq $inl{md5});
	next unless ($inl{inline_version} ge '0.40');
	unless (-f $o->{API}{location}) {
	    warn <<END if $^W;
Missing object file: $o->{API}{location}
For Inline file: $inl
END
	    next;
	}
	$o->{INLINE}{object_ready} = 1 unless $o->{CONFIG}{FORCE_BUILD};
	last;
    }
    unshift @::INC, $o->{API}{install_lib};
}

#==============================================================================
# Set things up so that the extension gets installed into the blib/arch.
# Then 'make install' will do the right thing.
#==============================================================================
sub install {
    my ($module, $DIRECTORY);
    my $o = shift;

    croak M64_install_not_c($o->{API}{language_id})
      unless uc($o->{API}{language_id}) =~ /^(C|CPP)$/ ;
    croak M36_usage_install_main()
      if ($o->{API}{pkg} eq 'main');
    croak M37_usage_install_auto()
      if $o->{CONFIG}{AUTONAME};
    croak M38_usage_install_name()
      unless $o->{CONFIG}{NAME};
    croak M39_usage_install_version()
      unless $o->{CONFIG}{VERSION};
    croak M40_usage_install_badname($o->{CONFIG}{NAME}, $o->{API}{pkg})
      unless $o->{CONFIG}{NAME} eq $o->{API}{pkg};
#	      $o->{CONFIG}{NAME} =~ /^$o->{API}{pkg}::\w(\w|::)+$/
#	     );

    my ($mod_name, $mod_ver, $ext_name, $ext_ver) = 
      ($o->{API}{pkg}, $ARGV[0], @{$o->{CONFIG}}{qw(NAME VERSION)});
    croak M41_usage_install_version_mismatch($mod_name, $mod_ver, 
					     $ext_name, $ext_ver)
      unless ($mod_ver eq $ext_ver);
    $o->{INLINE}{INST_ARCHLIB} = $ARGV[1];

    $o->{API}{version} = $o->{CONFIG}{VERSION};
    $o->{API}{module} = $o->{CONFIG}{NAME};
    my @modparts = split(/::/,$o->{API}{module});
    $o->{API}{modfname} = $modparts[-1];
    $o->{API}{modpname} = File::Spec->catdir(@modparts);
    $o->{API}{suffix} = $o->{INLINE}{ILSM_suffix};
    $o->{API}{build_dir} = File::Spec->catdir($o->{INLINE}{DIRECTORY},'build',
                                              $o->{API}{modpname});
    $o->{API}{directory} = $o->{INLINE}{DIRECTORY};
    my $cwd = Cwd::cwd();
    $o->{API}{install_lib} = 
      File::Spec->catdir($cwd,$o->{INLINE}{INST_ARCHLIB});
    $o->{API}{location} =
      File::Spec->catfile($o->{API}{install_lib},"auto",$o->{API}{modpname},
                          "$o->{API}{modfname}.$o->{INLINE}{ILSM_suffix}");
    unshift @::INC, $o->{API}{install_lib};
    $o->{INLINE}{object_ready} = 0;
}

#==============================================================================
# Create the .inl file for an object
#==============================================================================
sub write_inl_file {
    my $o = shift;
    my $inl = 
      File::Spec->catfile($o->{API}{install_lib},"auto",$o->{API}{modpname},
                          "$o->{API}{modfname}.inl");
    open INL, "> $inl"
      or croak "Can't create Inline validation file $inl";
    my $apiversion = $Config{apiversion} || $Config{xs_apiversion};
    print INL Inline::denter->new()
      ->indent(*md5, $o->{INLINE}{md5},
	       *name, $o->{API}{module},
	       *version, $o->{CONFIG}{VERSION},
	       *language, $o->{API}{language},
	       *language_id, $o->{API}{language_id},
	       *installed, $o->{CONFIG}{_INSTALL_},
	       *date_compiled, scalar localtime,
	       *inline_version, $Inline::VERSION,
	       *ILSM, { map {($_, $o->{INLINE}{"ILSM_$_"})}
			(qw( module suffix type ))
		      },
	       *Config, { (map {($_,$Config{$_})}
			   (qw( archname osname osvers
				cc ccflags ld so version
			      ))), 
			  (apiversion => $apiversion),
			},
	      );
    close INL;
}

#==============================================================================
# Get config hints
#==============================================================================
sub with_configs {
    my $o = shift;
    my @configs;
    for my $mod (@{$o->{CONFIG}{WITH}}) {
	my $ref = eval {
	    no strict 'refs';
	    &{$mod . "::Inline"}($o->{API}{language});
	};
	croak M25_no_WITH_support($mod, $@) if $@;
	push @configs, %$ref;
    }
    return @configs;
}

#==============================================================================
# Blindly untaint tainted fields in Inline object.
#==============================================================================
sub env_untaint {
    my $o = shift;

    for (keys %ENV) {
	($ENV{$_}) = $ENV{$_} =~ /(.*)/;
    }
    my $delim = $^O eq 'MSWin32' ? ';' : ':';
    $ENV{PATH} = join $delim, grep {not /^\./ and
				      not ((stat($_))[2] & 0022)
				  } split $delim, $ENV{PATH};
    map {($_) = /(.*)/} @INC;
}
#==============================================================================
# Blindly untaint tainted fields in Inline object.
#==============================================================================
sub obj_untaint {
    my $o = shift;

    ($o->{INLINE}{ILSM_module}) = $o->{INLINE}{ILSM_module} =~ /(.*)/;
    ($o->{API}{build_dir}) = $o->{API}{build_dir} =~ /(.*)/;
    ($o->{CONFIG}{DIRECTORY}) = $o->{CONFIG}{DIRECTORY} =~ /(.*)/;
    ($o->{API}{install_lib}) = $o->{API}{install_lib} =~ /(.*)/;
    ($o->{API}{modpname}) = $o->{API}{modpname} =~ /(.*)/;
    ($o->{API}{modfname}) = $o->{API}{modfname} =~ /(.*)/;
    ($o->{API}{language}) = $o->{API}{language} =~ /(.*)/;
    ($o->{API}{pkg}) = $o->{API}{pkg} =~ /(.*)/;
    ($o->{API}{module}) = $o->{API}{module} =~ /(.*)/;
}

#==============================================================================
# Clean the build directory from previous builds
#==============================================================================
sub clean_build {
    use strict;
    my ($prefix, $dir);
    my $o = shift;

    $prefix = $o->{INLINE}{DIRECTORY};
    opendir(BUILD, $prefix)
      or croak "Can't open build directory: $prefix for cleanup $!\n";

    while ($dir = readdir(BUILD)) {
        my $maybedir = File::Spec->catdir($prefix,$dir);
        if (($maybedir and -d $maybedir) and ($dir =~ /\w{36,}/)) {
            $o->rmpath($prefix,$dir); 
	}
    }

    close BUILD;
}

#==============================================================================
# Apply a list of filters to the source code
#==============================================================================
sub filter {
    my $o = shift;
    my $new_code = $o->{API}{code};
    for (@_) {
	croak M52_invalid_filter($_) unless ref;
	if (ref eq 'CODE') {
	    $new_code = $_->($new_code);
	}
	else {
	    $new_code = $_->filter($o, $new_code);
	}
    }
    return $new_code;
}

#==============================================================================
# User wants to report a bug
#==============================================================================
sub reportbug {
    use strict;
    my $o = shift;
    return if $o->{INLINE}{reportbug_handled}++;
    print STDERR <<END;
<-----------------------REPORTBUG Section------------------------------------->

REPORTBUG mode in effect.

Your Inline $o->{API}{language_id} code will be processed in the build directory:

  $o->{API}{build_dir}

A perl-readable bug report including your perl configuration and run-time
diagnostics will also be generated in the build directory.

When the program finishes please bundle up the above build directory with:

  tar czf Inline.REPORTBUG.tar.gz $o->{API}{build_dir}

and send "Inline.REPORTBUG.tar.gz" as an email attachment to the author
of the offending Inline::* module with the subject line:

  REPORTBUG: Inline.pm

Include in the email, a description of the problem and anything else that
you think might be helpful. Patches are welcome! :-\)

<-----------------------End of REPORTBUG Section------------------------------>
END
    my %versions;
    {
	no strict 'refs';
	%versions = map {eval "use $_();"; ($_, $ {$_ . '::VERSION'})}
	qw (Digest::MD5 Parse::RecDescent 
	    ExtUtils::MakeMaker File::Path FindBin 
	    Inline
	   );
    }

    $o->mkpath($o->{API}{build_dir});
    open REPORTBUG, "> ".File::Spec->catfile($o->{API}{build_dir},"REPORTBUG")
      or croak M24_open_for_output_failed
               (File::Spec->catfile($o->{API}{build_dir},"REPORTBUG"));
    %Inline::REPORTBUG_Inline_Object = ();
    %Inline::REPORTBUG_Perl_Config = ();
    %Inline::REPORTBUG_Module_Versions = ();
    print REPORTBUG Inline::denter->new()
      ->indent(*REPORTBUG_Inline_Object, $o, 
	       *REPORTBUG_Perl_Config, \%Config::Config,
	       *REPORTBUG_Module_Versions, \%versions,
	      );
    close REPORTBUG;
}

#==============================================================================
# Print a small report if PRINT_INFO option is set.
#==============================================================================
sub print_info {
    use strict;
    my $o = shift;

    print STDERR <<END;
<-----------------------Information Section----------------------------------->

Information about the processing of your Inline $o->{API}{language_id} code:

END
    
    print STDERR <<END if ($o->{INLINE}{object_ready});
Your module is already compiled. It is located at:
$o->{API}{location}

END

    print STDERR <<END if ($o->{INLINE}{object_ready} and $o->{CONFIG}{FORCE_BUILD});
But the FORCE_BUILD option is set, so your code will be recompiled.
I\'ll use this build directory:
$o->{API}{build_dir}

and I\'ll install the executable as:
$o->{API}{location}

END
    print STDERR <<END if (not $o->{INLINE}{object_ready});
Your source code needs to be compiled. I\'ll use this build directory:
$o->{API}{build_dir}

and I\'ll install the executable as:
$o->{API}{location}

END
    
    eval {
	print STDERR $o->info;
    };
    print $@ if $@;

    print STDERR <<END;

<-----------------------End of Information Section---------------------------->
END
}

#==============================================================================
# Hand off this invokation to Inline::MakeMaker
#==============================================================================
sub maker_utils {
    require Inline::MakeMaker;
    goto &Inline::MakeMaker::utils;
}

#==============================================================================
# Utility subroutines
#==============================================================================

#==============================================================================
# Make a path
#==============================================================================
sub mkpath {
    use strict;
    my ($o, $mkpath) = @_;
    my($volume,$dirs,$nofile) = File::Spec->splitpath($mkpath,1);
    my @parts = File::Spec->splitdir($dirs);
    my @done;
    foreach (@parts){
        push(@done,$_);
        my $path = File::Spec->catpath($volume,File::Spec->catdir(@done),"");
        -d $path || _mkdir($path, 0777);
    }
    croak M53_mkdir_failed($mkpath)
      unless -d $mkpath;
}

#==============================================================================
# Nuke a path (nicely)
#==============================================================================
sub rmpath {
    use strict;
    my ($o, $prefix, $rmpath) = @_;
# Nuke the target directory
    _rmtree(File::Spec->catdir($prefix ? ($prefix,$rmpath) : ($rmpath)));
# Remove any empty directories underneath the requested one
    my @parts = File::Spec->splitdir($rmpath);
    while (@parts){
        $rmpath = File::Spec->catdir($prefix ? ($prefix,@parts) : @parts);
        rmdir $rmpath
	  or last; # rmdir failed because dir was not empty
	pop @parts;
    }
}

sub _rmtree {
    my($roots) = @_;
    $roots = [$roots] unless ref $roots;
    my($root);
    foreach $root (@{$roots}) {
        if ( -d $root ) {
            my(@names,@paths);
            if (opendir MYDIR, $root) {
                @names = readdir MYDIR;
                closedir MYDIR;
            }
            else {
                croak M21_opendir_failed($root);
            }

            my $dot    = File::Spec->curdir();
            my $dotdot = File::Spec->updir();
            foreach my $name (@names) {
                next if $name eq $dot or $name eq $dotdot;
                my $maybefile = File::Spec->catfile($root,$name);
                push(@paths,$maybefile),next if $maybefile and -f $maybefile;
                push(@paths,File::Spec->catdir($root,$name));
            }

            _rmtree(\@paths);
	    ($root) = $root =~ /(.*)/ if UNTAINT;
            rmdir($root) or croak M54_rmdir_failed($root);
        }
        else { 
	    ($root) = $root =~ /(.*)/ if UNTAINT;
	    unlink($root) or croak M55_unlink_failed($root);
        }
    }
}

#==============================================================================
# Find the 'Inline' directory to use.
#==============================================================================
my $TEMP_DIR;
sub find_temp_dir {
    return $TEMP_DIR if $TEMP_DIR;
    
    my ($temp_dir, $home, $bin, $cwd, $env);
    $temp_dir = '';
    $env = $ENV{PERL_INLINE_DIRECTORY} || '';
    $home = $ENV{HOME} ? abs_path($ENV{HOME}) : '';
    
    if ($env and
	-d $env and
	-w $env) {
	$temp_dir = $env;
    }
    elsif ($cwd = abs_path('.') and
	   $cwd ne $home and
           -d File::Spec->catdir($cwd,".Inline") and
           -w File::Spec->catdir($cwd,".Inline")) {
        $temp_dir = File::Spec->catdir($cwd,".Inline");
    }
    elsif (require FindBin and
           $bin = $FindBin::Bin and
           -d File::Spec->catdir($bin,".Inline") and
           -w File::Spec->catdir($bin,".Inline")) {
        $temp_dir = File::Spec->catdir($bin,".Inline");
    } 
    elsif ($home and
           -d File::Spec->catdir($home,".Inline") and
           -w File::Spec->catdir($home,".Inline")) {
        $temp_dir = File::Spec->catdir($home,".Inline");
    } 
    elsif (defined $cwd and $cwd and
           -d File::Spec->catdir($cwd,"_Inline") and
           -w File::Spec->catdir($cwd,"_Inline")) {
        $temp_dir = File::Spec->catdir($cwd,"_Inline");
    }
    elsif (defined $bin and $bin and
           -d File::Spec->catdir($bin,"_Inline") and
           -w File::Spec->catdir($bin,"_Inline")) {
        $temp_dir = File::Spec->catdir($bin,"_Inline");
    } 
    elsif (defined $cwd and $cwd and
	   -d $cwd and
	   -w $cwd and
           _mkdir(File::Spec->catdir($cwd,"_Inline"), 0777)) {
        $temp_dir = File::Spec->catdir($cwd,"_Inline");
    }
    elsif (defined $bin and $bin and
	   -d $bin and
	   -w $bin and
           _mkdir(File::Spec->catdir($bin,"_Inline"), 0777)) {
        $temp_dir = File::Spec->catdir($bin,"_Inline");
    }

    croak M56_no_DIRECTORY_found()
      unless $temp_dir;
    return $TEMP_DIR = abs_path($temp_dir);
}

sub _mkdir {
    my $dir = shift;
    my $mode = shift || 0777;
    ($dir) = ($dir =~ /(.*)/) if UNTAINT;
    $dir =~ s|[/\\:]$||;
    return mkdir($dir, $mode);
}

#==============================================================================
# Error messages are autoloaded
#==============================================================================

sub M01_usage_use {
    my ($module) = @_;
    return <<END;
It is invalid to use '$module' directly. Please consult the Inline 
documentation for more information.

END
}

sub M02_usage {
    my $usage = <<END;
Invalid usage of Inline module. Valid usages are:
    use Inline;
    use Inline language => "source-string", config-pair-list;
    use Inline language => "source-file", config-pair-list;
    use Inline language => [source-line-list], config-pair-list;
    use Inline language => 'DATA', config-pair-list;
    use Inline language => 'Config', config-pair-list;
    use Inline Config => config-pair-list;
    use Inline with => module-list;
    use Inline shortcut-list;
END
# This is broken ????????????????????????????????????????????????????
    $usage .= <<END if defined $Inline::languages;

Supported languages:
    ${\ join(', ', sort keys %$Inline::languages)}

END
    return $usage;
}

sub M03_usage_bind {
    my $usage = <<END;
Invalid usage of the Inline->bind() function. Valid usages are:
    Inline->bind(language => "source-string", config-pair-list);
    Inline->bind(language => "source-file", config-pair-list);
    Inline->bind(language => [source-line-list], config-pair-list);
END

    $usage .= <<END if defined $Inline::languages;

Supported languages:
    ${\ join(', ', sort keys %$Inline::languages)}

END
    return $usage;
}

sub M04_error_nocode {
    my ($language) = @_;
    return <<END;
No $language source code found for Inline.

END
}

sub M05_error_eval {
    my ($subroutine, $msg) = @_;
    return <<END;
An eval() failed in Inline::$subroutine:
$msg

END
}

sub M06_code_file_failed_open {
    my ($file) = @_;
    return <<END;
Couldn't open Inline code file '$file':
$!

END
#'
}

sub M07_code_file_does_not_exist {
    my ($file) = @_;
    return <<END;
Inline assumes '$file' is a filename, 
and that file does not exist.

END
}

sub M08_no_DATA_source_code {
    my ($lang) = @_;
    return <<END;
No source code in DATA section for Inline '$lang' section.

END
}

sub M09_marker_mismatch {
    my ($marker, $lang) = @_;
    return <<END;
Marker '$marker' does not match Inline '$lang' section.

END
}

sub M10_usage_WITH_USING {
    return <<END;
Config option WITH or USING must be a module name or an array ref 
of module names.

END
}

sub M11_usage_DIRECTORY {
    my ($value) = @_;
    return <<END;
Invalid value '$value' for config option DIRECTORY

END
}

sub M12_usage_NAME {
    my ($name) = @_;
    return <<END;
Invalid value for NAME config option: '$name'

END
}

sub M13_usage_VERSION {
    my ($version) = @_;
    return <<END;
Invalid value for VERSION config option: '$version'
Must be of the form '#.##'. 
(Should also be specified as a string rather than a floating point number)

END
}

sub M14_usage_Config {
    return <<END;
As of Inline v0.30, use of the Inline::Config module is no longer supported
or allowed. If Inline::Config exists on your system, it can be removed. See
the Inline documentation for information on how to configure Inline.
(You should find it much more straightforward than Inline::Config :-)

END
}

sub M15_usage_install_directory {
    return <<END;
Can't use the DIRECTORY option when installing an Inline extension module.

END
#'
}

sub M16_DIRECTORY_mkdir_failed {
    my ($dir) = @_;
    return <<END;
Can't mkdir $dir to build Inline code.

END
#'
}

sub M17_config_open_failed {
    my ($dir) = @_;
    my $file = File::Spec->catfile(${dir},"config");
    return <<END;
Can't open ${file} for input.

END
#'
}

sub M18_error_old_version {
    my ($old_version, $directory) = @_;
    $old_version ||= '???';
    return <<END;
You are using Inline version $Inline::VERSION with a directory that was 
configured by Inline version $old_version. This version is no longer supported.
Please delete the following directory and try again:

    $directory

END
}

sub M19_usage_language {
    my ($language, $directory) = @_;
    return <<END;
Error. You have specified '$language' as an Inline programming language.

I currently only know about the following languages:
    ${ defined $Inline::languages ? 
       \ join(', ', sort keys %$Inline::languages) : \ ''
     }

If you have installed a support module for this language, try deleting the
config file from the following Inline DIRECTORY, and run again:

    $directory

END
}

sub M20_config_creation_failed {
    my ($dir) = @_;
    my $file = File::Spec->catfile(${dir},"config");
    return <<END;
Failed to autogenerate ${file}.

END
}

sub M21_opendir_failed {
    my ($dir) = @_;
    return <<END;
Can't open directory '$dir'.

END
#'
}

sub M22_usage_register {
    my ($language, $error) = @_;
    return <<END;
The module Inline::$language does not support the Inline API, because it does
properly support the register() method. This module will not work with Inline
and should be uninstalled from your system. Please advise your sysadmin.

The following error was generating from this module:
$error

END
}

sub M23_usage_alias_used {
    my ($new_mod, $alias, $old_mod) = @_;
    return <<END;
The module Inline::$new_mod is attempting to define $alias as an alias.
But $alias is also an alias for Inline::$old_mod.

One of these modules needs to be corrected or removed.
Please notify the system administrator.

END
}

sub M24_open_for_output_failed {
    my ($file) = @_;
    return <<END;
Can't open $file for output.
$!

END
#'
}

sub M25_no_WITH_support {
    my ($mod, $err) = @_;
    return <<END;
You have requested "use Inline with => '$mod'"
but '$mod' does not work with Inline.

$err

END
}

sub M26_error_version_without_name {
    return <<END;
Specifying VERSION option without NAME option is not permitted.

END
}

sub M27_module_not_indexed {
    my ($mod) = @_;
    return <<END;
You are attempting to load an extension for '$mod',
but there is no entry for that module in %INC.

END
}

sub M28_error_grokking_path {
    my ($path) = @_;
    return <<END;
Can't calculate a path from '$path' in %INC

END
}

sub M29_error_relative_path {
    my ($name, $path) = @_;
    return <<END;
Can't load installed extension '$name'
from relative path '$path'.

END
#'
}

sub M30_error_no_obj {
    my ($name, $pkg, $path) = @_;
    <<END;
The extension '$name' is not properly installed in path:
  '$path'

If this is a CPAN/distributed module, you may need to reinstall it on your
system.

To allow Inline to compile the module in a temporary cache, simply remove the
Inline config option 'VERSION=' from the $pkg module.

END
}

sub M31_inline_open_failed {
    my ($file) = @_;
    return <<END;
Can't open Inline validate file: 

    $file

$!

END
#'
}

sub M32_error_md5_validation {
    my ($md5, $inl) = @_;
    return <<END;
The source code fingerprint:

    $md5

does not match the one in:

    $inl

This module needs to be reinstalled.

END
}

sub M33_error_old_inline_version {
    my ($inl) = @_;
    return <<END;
The following extension is not compatible with this version of Inline.pm.

    $inl

You need to reinstall this extension.

END
}

sub M34_error_incorrect_version {
    my ($inl) = @_;
    return <<END;
The version of your extension does not match the one indicated by your
Inline source code, according to:

    $inl

This module should be reinstalled.

END
}

sub M35_error_no_object_file {
    my ($obj, $inl) = @_;
    return <<END;
There is no object file:
    $obj

For Inline validation file:
    $inl

This module should be reinstalled.

END
}

sub M36_usage_install_main {
    return <<END;
Can't install an Inline extension module from package 'main'.

END
#'
}

sub M37_usage_install_auto {
    return <<END;
Can't install an Inline extension module with AUTONAME enabled.

END
#'
}

sub M38_usage_install_name {
    return <<END;
An Inline extension module requires an explicit NAME.

END
}

sub M39_usage_install_version {
    return <<END;
An Inline extension module requires an explicit VERSION.

END
}

sub M40_usage_install_badname {
    my ($name, $pkg) = @_;
    return <<END;
The NAME '$name' is illegal for this Inline extension.
The NAME must match the current package name:
    $pkg

END
}

sub M41_usage_install_version_mismatch {
    my ($mod_name, $mod_ver, $ext_name, $ext_ver) = @_;
    <<END;
The version '$mod_ver' for module '$mod_name' doe not match
the version '$ext_ver' for Inline section '$ext_name'.

END
}

sub M42_usage_loader {
    return <<END;
ERROR. The loader that was invoked is for compiled languages only.

END
}

sub M43_error_bootstrap {
    my ($mod, $err) = @_;
    return <<END;
Had problems bootstrapping Inline module '$mod'

$err

END
}

sub M45_usage_with {
    return <<END;
Syntax error detected using 'use Inline with ...'.
Should be specified as:

    use Inline with => 'module1', 'module2', ..., 'moduleN';

END
}

sub M46_usage_with_bad {
    my $mod = shift;
    return <<END;
Syntax error detected using 'use Inline with => "$mod";'.
'$mod' could not be found.

END
}

sub M47_invalid_config_option {
    my ($option) = @_;
    return <<END;
Invalid Config option '$option'

END
#'
}

sub M48_usage_shortcuts {
    my ($shortcut) = @_;
    return <<END;
Invalid shortcut '$shortcut' specified.

Valid shortcuts are:
    VERSION, INFO, FORCE, NOCLEAN, CLEAN, UNTAINT, SAFE, UNSAFE, 
    GLOBAL, NOISY and REPORTBUG

END
}

sub M49_usage_unsafe {
    my ($terminate) = @_;
    return <<END .
You are using the Inline.pm module with the UNTAINT and SAFEMODE options,
but without specifying the DIRECTORY option. This is potentially unsafe.
Either use the DIRECTORY option or turn off SAFEMODE.

END
      ($terminate ? <<END : "");
Since you are running as the a privledged user, Inline.pm is terminating.

END
}

sub M51_unused_DATA {
    return <<END;
One or more DATA sections were not processed by Inline.

END
}

sub M52_invalid_filter {
    my ($filter) = @_;
    return <<END;
Invalid filter '$filter' is not a reference.

END
}

sub M53_mkdir_failed {
    my ($dir) = @_;
    return <<END;
Couldn't make directory path '$dir'.

END
#'
}

sub M54_rmdir_failed {
    my ($dir) = @_;
    return <<END;
Can't remove directory '$dir': 

$!

END
#'
}

sub M55_unlink_failed {
    my ($file) = @_;
    return <<END;
Can't unlink file '$file': 

$!

END
#'
}

sub M56_no_DIRECTORY_found {
    return <<END;
Couldn't find an appropriate DIRECTORY for Inline to use.

END
#'
}

sub M57_wrong_architecture {
    my ($ext, $arch, $thisarch) = @_;
    return <<END;
The extension '$ext'
is built for perl on the '$arch' platform.
This is the '$thisarch' platform.

END
}

sub M58_site_install {
    return <<END;
You have specified the SITE_INSTALL command. Support for this option has 
been removed from Inline since version 0.40. It has been replaced by the
use of Inline::MakeMaker in your Makefile.PL. Please see the Inline
documentation for more help on creating and installing Inline based modules.

END
}

sub M59_bad_inline_file {
    my ($lang) = @_;
    return <<END;
Could not find any Inline source code for the '$lang' language using 
the Inline::Files module.

END
}

sub M60_no_inline_files {
    return <<END;
It appears that you have requested to use Inline with Inline::Files.
You need to explicitly 'use Inline::Files;' before your 'use Inline'.

END
}

sub M61_not_parsed {
    return <<END;
It does not appear that your program has been properly parsed by Inline::Files.

END
}

sub M62_invalid_config_file {
    my ($config) = @_;
    return <<END;
You are using a config file that was created by an older version of Inline:

    $config

This file and all the other components in its directory are no longer valid
for this version of Inline. The best thing to do is simply delete all the 
contents of the directory and let Inline rebuild everything for you. Inline 
will do this automatically when you run your programs.

END
}

sub M63_no_source {
    my ($pkg) = @_;
    return <<END;
This module $pkg can not be loaded and has no source code.
You may need to reinstall this module.

END
}

sub M64_install_not_c {
    my ($lang) = @_;
    return <<END;
Invalid attempt to install an Inline module using the '$lang' language.

Only C and CPP (C++) based modules are currently supported.

END
}

1;

__END__

=head1 NAME

Inline - Write Perl subroutines in other programming languages.

=head1 SYNOPSIS

    use Inline C;
    
    print "9 + 16 = ", add(9, 16), "\n";
    print "9 - 16 = ", subtract(9, 16), "\n";
 
    __END__
    __C__
    int add(int x, int y) {
      return x + y;
    }
 
    int subtract(int x, int y) {
      return x - y;
    }

=head1 DESCRIPTION

The Inline module allows you to put source code from other programming
languages directly "inline" in a Perl script or module. The code is
automatically compiled as needed, and then loaded for immediate access
from Perl.

Inline saves you from the hassle of having to write and compile your own
glue code using facilities like XS or SWIG. Simply type the code where
you want it and run your Perl as normal. All the hairy details are
handled for you. The compilation and installation of your code chunks
all happen transparently; all you will notice is the delay of
compilation on the first run.

The Inline code only gets compiled the first time you run it (or
whenever it is modified) so you only take the performance hit once. Code
that is Inlined into distributed modules (like on the CPAN) will get
compiled when the module is installed, so the end user will never notice
the compilation time.

Best of all, it works the same on both Unix and Microsoft Windows. See
L<Inline-Support> for support information.

=head2 Why Inline?

Do you want to know "Why would I use other languages in Perl?" or "Why
should I use Inline to do it?"? I'll try to answer both.

=over 4

=item Why would I use other languages in Perl?

The most obvious reason is performance. For an interpreted language,
Perl is very fast. Many people will say "Anything Perl can do, C can do
faster". (They never mention the development time :-) Anyway, you may be
able to remove a bottleneck in your Perl code by using another language,
without having to write the entire program in that language. This keeps
your overall development time down, because you're using Perl for all of
the non-critical code.

Another reason is to access functionality from existing API-s that use
the language. Some of this code may only be available in binary form.
But by creating small subroutines in the native language, you can
"glue" existing libraries to your Perl. As a user of the CPAN, you know
that code reuse is a good thing. So why throw away those Fortran
libraries just yet?

If you are using Inline with the C language, then you can access the
full internals of Perl itself. This opens up the floodgates to both
extreme power and peril.

Maybe the best reason is "Because you want to!". Diversity keeps the
world interesting. TMTOWTDI!

=item Why should I use Inline to do it?

There are already two major facilities for extending Perl with C. They
are XS and SWIG. Both are similar in their capabilities, at least as far
as Perl is concerned. And both of them are quite difficult to learn
compared to Inline.

There is a big fat learning curve involved with setting up and using the
XS environment. You need to get quite intimate with the following docs:

 * perlxs
 * perlxstut
 * perlapi
 * perlguts
 * perlmod
 * h2xs
 * xsubpp
 * ExtUtils::MakeMaker

With Inline you can be up and running in minutes. There is a C Cookbook
with lots of short but complete programs that you can extend to your
real-life problems. No need to learn about the complicated build
process going on in the background. You don't even need to compile the
code yourself. Inline takes care of every last detail except writing
the C code.

Perl programmers cannot be bothered with silly things like compiling.
"Tweak, Run, Tweak, Run" is our way of life. Inline does all the dirty
work for you.

Another advantage of Inline is that you can use it directly in a script.
You can even use it in a Perl one-liner. With XS and SWIG, you always
set up an entirely separate module. Even if you only have one or two
functions. Inline makes easy things easy, and hard things possible. Just
like Perl.

Finally, Inline supports several programming languages (not just C and
C++). As of this writing, Inline has support for C, C++, Java, Python,
Ruby, Tcl, Assembler, Basic, Guile, Befunge, Octave, Awk, BC, TT
(Template Toolkit), WebChat and even PERL. New Inline Language Support
Modules (ILSMs) are regularly being added. See L<Inline-API> for details
on how to create your own ILSM.

=back

=head1 Using the Inline.pm Module

Inline is a little bit different than most of the Perl modules that you
are used to. It doesn't import any functions into your namespace and it
doesn't have any object oriented methods. Its entire interface (with two
minor exceptions) is specified through the C<'use Inline ...'> command.

This section will explain all of the different ways to C<use Inline>. If
you want to begin using C with Inline immediately, see
L<Inline::C-Cookbook>.

=head2 The Basics

The most basic form for using Inline is:

    use Inline X => "X source code";

where 'X' is one of the supported Inline programming languages. The
second parameter identifies the source code that you want to bind
to Perl. The source code can be specified using any of the
following syntaxes:

=over 4

=item The DATA Keyword.

    use Inline Java => 'DATA';
    
    # Perl code goes here ...
    
    __DATA__
    __Java__
    /* Java code goes here ... */

The easiest and most visually clean way to specify your source code in
an Inline Perl program is to use the special C<DATA> keyword. This tells
Inline to look for a special marker in your C<DATA> filehandle's input
stream. In this example the special marker is C<__Java__>, which is the
programming language surrounded by double underscores.

In case you've forgotten, the C<DATA> pseudo file is comprised of all
the text after the C<__END__> or C<__DATA__> section of your program. If
you're working outside the C<main> package, you'd best use the
C<__DATA__> marker or else Inline will not find your code.

Using this scheme keeps your Perl code at the top, and all the ugly Java
stuff down below where it belongs. This is visually clean and makes for
more maintainable code. An excellent side benefit is that you don't have
to escape any characters like you might in a Perl string. The source
code is verbatim. For these reasons, I prefer this method the most.

The only problem with this style is that since Perl can't read the
C<DATA> filehandle until runtime, it obviously can't bind your functions
until runtime. The net effect of this is that you can't use your Inline
functions as barewords (without predeclaring them) because Perl has no
idea they exist during compile time.

=item The FILE and BELOW keywords.

    use Inline::Files;
    use Inline Java => 'FILE';
    
    # Perl code goes here ...
    
    __JAVA__
    /* Java code goes here ... */

This is the newest method of specifying your source code. It makes use
of the Perl module C<Inline::Files> written by Damian Conway. The basic
style and meaning are the same as for the C<DATA> keyword, but there are
a few syntactic and semantic twists.

First, you must say 'use Inline::Files' before you 'use Inline' code
that needs those files. The special 'C<DATA>' keyword is replaced by
either 'C<FILE>' or 'C<BELOW>'. This allows for the bad pun idiom of:

    use Inline C => 'BELOW';

You can omit the C<__DATA__> tag now. Inline::Files is a source filter
that will remove these sections from your program before Perl compiles
it. They are then available for Inline to make use of. And since this
can all be done at compile time, you don't have to worry about the
caveats of the 'DATA' keyword.

This module has a couple small gotchas. Since Inline::Files only
recognizes file markers with capital letters, you must specify the
capital form of your language name. Also, there is a startup time
penalty for using a source code filter.

At this point Inline::Files is alpha software and use of it is
experimental. Inline's integration of this module is also fledgling at
the time being. One of things I plan to do with Inline::Files is to get
line number info so when an extension doesn't compile, the error
messages will point to the correct source file and line number.

My best advice is to use Inline::Files for testing (especially as
support for it improves), but use DATA for production and
distributed/CPAN code.

=item Strings

    use Inline Java => <<'END';
    
    /* Java code goes here ... */
    END
    
    # Perl code goes here ...

You also just specify the source code as a single string. A handy way to
write the string is to use Perl's "here document" style of quoting. This
is ok for small functions but can get unwieldy in the large. On the
other hand, the string variant probably has the least startup penalty
and all functions are bound at compile time.

If you wish to put the string into a scalar variable, please be aware
that the C<use> statement is a compile time directive. As such, all the
variables it uses must also be set at compile time, C<before> the 'use
Inline' statement. Here is one way to do it:

    my $code;
    BEGIN {
        $code = <<END;
    
    /* Java code goes here ... */
    END
    }
    use Inline Java => $code;
    
    # Perl code goes here ...

=item The bind() Function

An alternative to using the BEGIN block method is to specify the source
code at run time using the 'Inline->bind()' method. (This is one of the
interface exceptions mentioned above) The C<bind()> method takes the
same arguments as C<'use Inline ...'>.

    my $code = <<END;
    
    /* Java code goes here ... */
    END
    
    Inline->bind(Java => $code);

You can think of C<bind()> as a way to C<eval()> code in other
programming languages.

Although bind() is a powerful feature, it is not recommended for use in
Inline based modules. In fact, it won't work at all for installable
modules. See instructions below for creating modules with Inline.

=item Other Methods

The source code for Inline can also be specified as an external
filename, a reference to a subroutine that returns source code, or a
reference to an array that contains lines of source code. These methods
are less frequently used but may be useful in some situations.

=item Shorthand

If you are using the 'DATA' or 'FILE' methods described above B<and>
there are no extra parameters, you can omit the keyword altogether.
For example:

    use Inline 'Java';
    
    # Perl code goes here ...
    
    __DATA__
    __Java__
    /* Java code goes here ... */

or

    use Inline::Files;
    use Inline 'Java';
    
    # Perl code goes here ...
    
    __JAVA__
    /* Java code goes here ... */

=back

=head2 More about the DATA Section

If you are writing a module, you can also use the DATA section for POD
and AutoLoader subroutines. Just be sure to put them before the first
Inline marker. If you install the helper module C<Inline::Filters>, you
can even use POD inside your Inline code. You just have to specify a
filter to strip it out.

You can also specify multiple Inline sections, possibly in different
programming languages. Here is another example:

    # The module Foo.pm
    package Foo;
    use AutoLoader;
    
    use Inline C;
    use Inline C => DATA => FILTERS => 'Strip_POD';
    use Inline Python;
    
    1;
    
    __DATA__
    
    sub marine {
        # This is an autoloaded subroutine
    }
    
    =head1 External subroutines
    
    =cut
    
    __C__
    /* First C section */
    
    __C__
    /* Second C section */
    =head1 My C Function
    
    Some POD doc.
    
    =cut
    
    __Python__
    """A Python Section"""

An important thing to remember is that you need to have one "use
Inline Foo => 'DATA'" for each "__Foo__" marker, and they must be in
the same order. This allows you to apply different configuration
options to each section.

=head2 Configuration Options

Inline trys to do the right thing as often as possible. But
sometimes you may need to override the default actions. This is easy
to do. Simply list the Inline configuration options after the
regular Inline parameters. All congiguration options are specified
as (key, value) pairs.

    use Inline (C => 'DATA',
                DIRECTORY => './inline_dir',
                LIBS => '-lfoo',
                INC => '-I/foo/include',
                PREFIX => 'XXX_',
                WARNINGS => 0,
               );

You can also specify the configuration options on a separate Inline call
like this:

    use Inline (C => Config =>
                DIRECTORY => './inline_dir',
                LIBS => '-lfoo',
                INC => '-I/foo/include',
                PREFIX => 'XXX_',
                WARNINGS => 0,
               );
    use Inline C => <<'END_OF_C_CODE';

The special keyword C<'Config'> tells Inline that this is a
configuration-only call. No source code will be compiled or bound to
Perl.

If you want to specify global configuration options that don't apply
to a particular language, just leave the language out of the call.
Like this:

    use Inline Config => WARNINGS => 0;

The Config options are inherited and additive. You can use as many
Config calls as you want. And you can apply different options to
different code sections. When a source code section is passed in,
Inline will apply whichever options have been specified up to that
point. Here is a complex configuration example:

    use Inline (Config => 
                DIRECTORY => './inline_dir',
               );
    use Inline (C => Config =>
                LIBS => '-lglobal',
               );
    use Inline (C => 'DATA',         # First C Section
                LIBS => ['-llocal1', '-llocal2'],
               );
    use Inline (Config => 
                WARNINGS => 0,
               );
    use Inline (Python => 'DATA',    # First Python Section
                LIBS => '-lmypython1',
               );
    use Inline (C => 'DATA',         # Second C Section
                LIBS => [undef, '-llocal3'],
               );

The first C<Config> applies to all subsequent calls. The second
C<Config> applies to all subsequent C<C> sections (but not C<Python>
sections). In the first C<C> section, the external libraries C<global>,
C<local1> and C<local2> are used. (Most options allow either string or
array ref forms, and do the right thing.) The C<Python> section does not
use the C<global> library, but does use the same C<DIRECTORY>, and has
warnings turned off. The second C<C> section only uses the C<local3>
library. That's because a value of C<undef> resets the additive
behavior.

The C<DIRECTORY> and C<WARNINGS> options are generic Inline options. All
other options are language specific. To find out what the C<C> options
do, see C<Inline::C>.

=head2 On and Off

If a particular config option has value options of 1 and 0, you can use
the ENABLE and DISABLE modifiers. In other words, this:

    use Inline Config => 
               FORCE_BUILD => 1,
               CLEAN_AFTER_BUILD => 0;

could be reworded as:

    use Inline Config =>
               ENABLE => FORCE_BUILD,
               DISABLE => CLEAN_AFTER_BUILD;

=head2 Playing 'with' Others

Inline has a special configuration syntax that tells it to get more
configuration options from other Perl modules. Here is an example:

    use Inline with => 'Event';

This tells Inline to load the module C<Event.pm> and ask it for
configuration information. Since C<Event> has a C API of its own, it can
pass Inline all of the information it needs to be able to use C<Event> C
callbacks seamlessly.

That means that you don't need to specify the typemaps, shared
libraries, include files and other information required to get
this to work.

You can specify a single module or a list of them. Like:

    use Inline with => qw(Event Foo Bar);

Currently, C<Event> is the only module that works I<with> Inline.

=head2 Inline Shortcuts

Inline lets you set many configuration options from the command line.
These options are called 'shortcuts'. They can be very handy, especially
when you only want to set the options temporarily, for say, debugging.

For instance, to get some general information about your Inline code in
the script C<Foo.pl>, use the command:

    perl -MInline=INFO Foo.pl

If you want to force your code to compile, even if its already done, use:

    perl -MInline=FORCE Foo.pl

If you want to do both, use:

    perl -MInline=INFO -MInline=FORCE Foo.pl

or better yet:

    perl -MInline=INFO,FORCE Foo.pl

=head2 The Inline DIRECTORY

Inline needs a place to build your code and to install the results of
the build. It uses a single directory named C<'.Inline/'> under normal
circumstances. If you create this directory in your home directory, the
current directory or in the directory where your program resides, Inline
will find and use it. You can also specify it in the environment
variable C<PERL_INLINE_DIRECTORY> or directly in your program, by using
the C<DIRECTORY> keyword option. If Inline cannot find the directory in
any of these places it will create a C<'_Inline/'> directory in either
your current directory or the directory where your script resides.

One of the key factors to using Inline successfully, is understanding
this directory. When developing code it is usually best to create this
directory (or let Inline do it) in your current directory. Remember that
there is nothing sacred about this directory except that it holds your
compiled code. Feel free to delete it at any time. Inline will simply
start from scratch and recompile your code on the next run. If you have
several programs that you want to force to recompile, just delete your
C<'.Inline/'> directory.

It is probably best to have a separate C<'.Inline/'> directory for each
project that you are working on. You may want to keep stable code in the
<.Inline/> in your home directory. On multi-user systems, each user
should have their own C<'.Inline/'> directories. It could be a security
risk to put the directory in a shared place like C</tmp/>.

=head2 Debugging Inline Errors

All programmers make mistakes. When you make a mistake with Inline, like
writing bad C code, you'll get a big error report on your screen. This
report tells you where to look to do the debugging. Some languages may also
dump out the error messages generated from the build.

When Inline needs to build something it creates a subdirectory under
your C<DIRECTORY/build/> directory. This is where it writes all the
components it needs to build your extension. Things like XS files,
Makefiles and output log files.

If everything goes OK, Inline will delete this subdirectory. If there is
an error, Inline will leave the directory intact and print its location.
The idea is that you are supposed to go into that directory and figure
out what happened.

Read the doc for your particular Inline Language Support Module for more
information.

=head2 The 'config' Registry File

Inline keeps a cached file of all of the Inline Language Support
Module's meta data in a file called C<config>. This file can be found in
your C<DIRECTORY> directory. If the file does not exist, Inline creates
a new one. It will search your system for any module beginning with
C<Inline::>. It will then call that module's C<register()> method to get
useful information for future invocations.

Whenever you add a new ILSM, you should delete this file so that Inline
will auto-discover your newly installed language module.

=head1 Configuration Options

This section lists all of the generic Inline configuration options. For
language specific configuration, see the doc for that language.

=head2 DIRECTORY

The C<DIRECTORY> config option is the directory that Inline uses to both
build and install an extension.

Normally Inline will search in a bunch of known places for a directory
called C<'.Inline/'>. Failing that, it will create a directory called
C<'_Inline/'>

If you want to specify your own directory, use this configuration
option.

Note that you must create the C<DIRECTORY> directory yourself. Inline
will not do it for you.

=head2 NAME

You can use this option to set the name of your Inline extension object
module. For example:

    use Inline C => 'DATA',
               NAME => 'Foo::Bar';

would cause your C code to be compiled in to the object:

    lib/auto/Foo/Bar/Bar.so
    lib/auto/Foo/Bar/Bar.inl

(The .inl component contains dependency information to make sure the
source code is in sync with the executable)

If you don't use NAME, Inline will pick a name for you based on your
program name or package name. In this case, Inline will also enable the
AUTONAME option which mangles in a small piece of the MD5 fingerprint
into your object name, to make it unique.

=head2 AUTONAME

This option is enabled whenever the NAME parameter is not specified. To
disable it say:

    use Inline C => 'DATA',
               DISABLE => 'AUTONAME';

AUTONAME mangles in enough of the MD5 fingerprint to make your module
name unique. Objects created with AUTONAME will never get replaced. That
also means they will never get cleaned up automatically.

AUTONAME is very useful for small throw away scripts. For more serious
things, always use the NAME option.

=head2 VERSION

Specifies the version number of the Inline extension object. It is used
B<only> for modules, and it must match the global variable $VERSION.
Additionally, this option should used if (and only if) a module is being
set up to be installed permanently into the Perl sitelib tree. Inline
will croak if you use it otherwise.

The presence of the VERSION parameter is the official way to let Inline
know that your code is an installable/installed module. Inline will
never generate an object in the temporary cache (_Inline/ directory) if
VERSION is set. It will also never try to recompile a module that was
installed into someone's Perl site tree.

So the basic rule is develop without VERSION, and deliver with VERSION.

=head2 WITH

C<WITH> can also be used as a configuration option instead of using the
special 'with' syntax. Do this if you want to use different sections of
Inline code I<with> different modules. (Probably a very rare usage)

    use Event;
    use Inline C => DATA => WITH => 'Event';

Modules specified using the config form of C<WITH> will B<not> be
automatically required. You must C<use> them yourself.

=head2 GLOBAL_LOAD

This option is for compiled languages only. It tells Inline to tell
DynaLoader to load an object file in such a way that its symbols can be
dynamically resolved by other object files. May not work on all
platforms. See the C<GLOBAL> shortcut below.

=head2 UNTAINT

You must use this option whenever you use Perl's C<-T> switch, for taint
checking. This option tells Inline to blindly untaint all tainted
variables. It also turns on SAFEMODE by default. See the C<UNTAINT>
shortcut below.

=head2 SAFEMODE

Perform extra safety checking, in an attempt to thwart malicious code.
This option cannot guarantee security, but it does turn on all the
currently implemented checks.

There is a slight startup penalty by using SAFEMODE. Also, using UNTAINT
automatically turns this option on. If you need your code to start
faster under C<-T> (taint) checking, you'll need to turn this option off
manually. Only do this if you are not worried about security risks. See
the C<UNSAFE> shortcut below.

=head2 FORCE_BUILD

Makes Inline build (compile) the source code every time the program is
run. The default is 0. See the C<FORCE> shortcut below.

=head2 BUILD_NOISY

Tells ILSMs that they should dump build messages to the terminal rather
than be silent about all the build details.

=head2 BUILD_TIMERS

Tells ILSMs to print timing information about how long each build phase
took. Usually requires C<Time::HiRes>.

=head2 CLEAN_AFTER_BUILD

Tells Inline to clean up the current build area if the build was
successful. Sometimes you want to DISABLE this for debugging. Default is
1. See the C<NOCLEAN> shortcut below.

=head2 CLEAN_BUILD_AREA

Tells Inline to clean up the old build areas within the entire Inline
DIRECTORY. Default is 0. See the C<CLEAN> shortcut below.

=head2 PRINT_INFO

Tells Inline to print various information about the source code. Default
is 0. See the C<INFO> shortcut below.

=head2 PRINT_VERSION

Tells Inline to print Version info about itself. Default is 0. See the
C<VERSION> shortcut below.

=head2 REPORTBUG

Puts Inline into 'REPORTBUG' mode, which is what you want if you desire
to report a bug.

=head2 WARNINGS

This option tells Inline whether to print certain warnings. Default is 1.

=head1 Inline Configuration Shortcuts

This is a list of all the shorcut configuration options currently
available for Inline. Specify them from the command line when running
Inline scripts.

    perl -MInline=NOCLEAN inline_script.pl

or 

    perl -MInline=Info,force,NoClean inline_script.pl

You can specify multiple shortcuts separated by commas. They are not
case sensitive. You can also specify shorcuts inside the Inline program
like this:

    use Inline 'Info', 'Force', 'Noclean';

NOTE: 
If a C<'use Inline'> statement is used to set shortcuts, it can not be
used for additional purposes.

=over 4

=item CLEAN

Tells Inline to remove any build directories that may be lying around in
your build area. Normally these directories get removed immediately
after a successful build. Exceptions are when the build fails, or when
you use the NOCLEAN or REPORTBUG options.

=item FORCE

Forces the code to be recompiled, even if everything is up to date.

=item GLOBAL

Turns on the GLOBAL_LOAD option.

=item INFO

This is a very useful option when you want to know what's going on under
the hood. It tells Inline to print helpful information to C<STDERR>.
Among the things that get printed is a list of which Inline functions
were successfully bound to Perl.

=item NOCLEAN

Tells Inline to leave the build files after compiling.

=item NOISY

Use the BUILD_NOISY option to print messages during a build.

=item REPORTBUG

Puts Inline into 'REPORTBUG' mode, which does special processing when
you want to report a bug. REPORTBUG also automatically forces a build,
and doesn't clean up afterwards. This is so that you can tar and mail
the build directory to me. REPORTBUG will print exact instructions on
what to do. Please read and follow them carefully.

NOTE: REPORTBUG informs you to use the tar command. If your system does not have tar, please use the equivalent C<zip> command.

=item SAFE

Turns SAFEMODE on. UNTAINT will turn this on automatically. While this
mode performs extra security checking, it does not guarantee safety.

=item SITE_INSTALL

This parameter used to be used for creating installable Inline modules.
It has been removed from Inline altogether and replaced with a much
simpler and more powerful mechanism, C<Inline::MakeMaker>. See the
section below on how to create modules with Inline.

=item TIMERS

Turn on BUILD_TIMERS to get extra diagnostic info about builds.

=item UNSAFE

Turns SAFEMODE off. Use this in combination with UNTAINT for slightly
faster startup time under C<-T>. Only use this if you are sure the
environment is safe.

=item UNTAINT

Turn the UNTAINT option on. Used with C<-T> switch.

=item VERSION

Tells Inline to report its release version.

=back

=head1 Writing Modules with Inline

Writing CPAN modules that use C code is easy with Inline. Let's say that
you wanted to write a module called C<Math::Simple>. Start by using the
following command:

    h2xs -PAXn Math::Simple

This will generate a bunch of files that form a skeleton of what you
need for a distributable module. (Read the h2xs manpage to find out what
the options do) Next, modify the C<Simple.pm> file to look like this:

    package Math::Simple;
    $VERSION = '1.23';

    use base 'Exporter';
    @EXPORT_OK = qw(add subtract);
    use strict;
    
    use Inline C => 'DATA',
               VERSION => '1.23',
               NAME => 'Math::Simple';
    
    1;
    
    __DATA__
    
    =pod
    
    =cut
    
    __C__
    int add(int x, int y) {
      return x + y;
    }
    
    int subtract(int x, int y) {
      return x - y;
    }

The important things to note here are that you B<must> specify a C<NAME>
and C<VERSION> parameter. The C<NAME> must match your module's package
name. The C<VERSION> parameter must match your module's C<$VERSION>
variable and they must be of the form C</^\d\.\d\d$/>.

NOTE: 
These are Inline's sanity checks to make sure you know what you're doing
before uploading your code to CPAN. They insure that once the module has
been installed on someone's system, the module would not get
automatically recompiled for any reason. This makes Inline based modules
work in exactly the same manner as XS based ones.

Finally, you need to modify the Makefile.PL. Simply change:

    use ExtUtils::MakeMaker;

to

    use Inline::MakeMaker;

When the person installing C<Math::Simple> does a "C<make>", the
generated Makefile will invoke Inline in such a way that the C code will
be compiled and the executable code will be placed into the C<./blib>
directory. Then when a "C<make install>" is done, the module will be
copied into the appropiate Perl sitelib directory (which is where an
installed module should go).

Now all you need to do is:

    perl Makefile.PL
    make dist

That will generate the file C<Math-Simple-0.20.tar.gz> which is a
distributable package. That's all there is to it.

IMPORTANT NOTE: 
Although the above steps will produce a workable module, you still have
a few more responsibilities as a budding new CPAN author. You need to
write lots of documentation and write lots of tests. Take a look at some
of the better CPAN modules for ideas on creating a killer test harness.
Actually, don't listen to me, go read these:

    perldoc perlnewmod
    http://www.cpan.org/modules/04pause.html
    http://www.cpan.org/modules/00modlist.long.html

=head1 How Inline Works

In reality, Inline just automates everything you would need to do if you
were going to do it by hand (using XS, etc).

Inline performs the following steps:

=over 4

=item 1) Receive the Source Code

Inline gets the source code from your script or module with a statements
like the following:

    use Inline C => "Source-Code";

or

    use Inline;
    bind Inline C => "Source-Code";

where C<C> is the programming language of the source code, and
C<Source-Code> is a string, a file name, an array reference, or the
special C<'DATA'> keyword.

Since Inline is coded in a "C<use>" statement, everything is done during
Perl's compile time. If anything needs to be done that will affect the
C<Source-Code>, it needs to be done in a C<BEGIN> block that is
I<before> the "C<use Inline ...>" statement. If you really need to
specify code to Inline at runtime, you can use the C<bind()> method.

Source code that is stowed in the C<'DATA'> section of your code, is
read in by an C<INIT> subroutine in Inline. That's because the C<DATA>
filehandle is not available at compile time.

=item 2) Check if the Source Code has been Built

Inline only needs to build the source code if it has not yet been built.
It accomplishes this seemingly magical task in an extremely simple and
straightforward manner. It runs the source text through the
C<Digest::MD5> module to produce a 128-bit "fingerprint" which is
virtually unique. The fingerprint along with a bunch of other
contingency information is stored in a C<.inl> file that sits next to
your executable object. For instance, the C<C> code from a script called
C<example.pl> might create these files:

    example_pl_3a9a.so
    example_pl_3a9a.inl

If all the contingency information matches the values stored in the
C<.inl> file, then proceed to step 8. (No compilation is necessary)

=item 3) Find a Place to Build and Install

At this point Inline knows it needs to build the source code. The first
thing to figure out is where to create the great big mess associated
with compilation, and where to put the object when it's done.

By default Inline will try to build and install under the first place
that meets one of the following conditions:

    A) The DIRECTORY= config option; if specified
    B) The PERL_INLINE_DIRECTORY environment variable; if set
    C) .Inline/ (in current directory); if exists and $PWD != $HOME
    D) bin/.Inline/ (in directory of your script); if exists
    E) ~/.Inline/; if exists
    F) ./_Inline/; if exists
    G) bin/_Inline; if exists
    H) Create ./_Inline/; if possible
    I) Create bin/_Inline/; if possible

Failing that, Inline will croak. This is rare and easily remedied by
just making a directory that Inline will use;

If the module option is being compiled for permanent installation, then
Inline will only use C<./_Inline/> to build in, and the
C<$Config{installsitearch}> directory to install the executable in. This
action is caused by Inline::MakeMaker, and is intended to be used in
modules that are to be distributed on the CPAN, so that they get
installed in the proper place.

=item 4) Parse the Source for Semantic Cues

Inline::C uses the module C<Parse::RecDescent> to parse through your
chunks of C source code and look for things that it can create run-time
bindings to. In C<C> it looks for all of the function definitions and
breaks them down into names and data types. These elements are used to
correctly bind the C<C> function to a C<Perl> subroutine. Other Inline
languages like Python and Java actually use the C<python> and C<javac>
modules to parse the Inline code.

=item 5) Create the Build Environment

Now Inline can take all of the gathered information and create an
environment to build your source code into an executable. Without going
into all the details, it just creates the appropriate directories,
creates the appropriate source files including an XS file (for C) and a
C<Makefile.PL>.

=item 6) Build the Code and Install the Executable

The planets are in alignment. Now for the easy part. Inline just does
what you would do to install a module. "C<perl Makefile.PL && make &&
make test && make install>". If something goes awry, Inline will croak
with a message indicating where to look for more info.

=item 7) Tidy Up

By default, Inline will remove all of the mess created by the build
process, assuming that everything worked. If the build fails, Inline
will leave everything intact, so that you can debug your errors. Setting
the C<NOCLEAN> shortcut option will also stop Inline from cleaning up.

=item 8) DynaLoad the Executable

For C (and C++), Inline uses the C<DynaLoader::bootstrap> method to pull
your external module into C<Perl> space. Now you can call all of your
external functions like Perl subroutines.

Other languages like Python and Java, provide their own loaders.

=back

=head1 SEE ALSO

For information about using Inline with C see L<Inline::C>.

For sample programs using Inline with C see L<Inline::C-Cookbook>.

For "Formerly Answered Questions" about Inline, see L<Inline-FAQ>.

For information on supported languages and platforms see
L<Inline-Support>.

For information on writing your own Inline Language Support Module, see
L<Inline-API>.

Inline's mailing list is inline@perl.org

To subscribe, send email to inline-subscribe@perl.org

=head1 BUGS AND DEFICIENCIES

When reporting a bug, please do the following:

 - Put "use Inline REPORTBUG;" at the top of your code, or
   use the command line option "perl -MInline=REPORTBUG ...".
 - Run your code.
 - Follow the printed directions.

=head1 AUTHOR

Brian Ingerson <INGY@cpan.org>

Neil Watkiss <NEILW@cpan.org> is the author of C<Inline::CPP>,
C<Inline::Python>, C<Inline::Ruby>, C<Inline::ASM>, C<Inline::Struct>
and C<Inline::Filters>. He is known in the innermost Inline circles as
the "Boy Wonder".

=head1 COPYRIGHT

Copyright (c) 2000, 2001, 2002. Brian Ingerson. All rights reserved.

Copyright (c) 2005. Ingy döt Net. All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See http://www.perl.com/perl/misc/Artistic.html

=cut
