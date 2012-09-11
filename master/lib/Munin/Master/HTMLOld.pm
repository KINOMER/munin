package Munin::Master::HTMLOld;

=begin comment
-*- perl -*-

This is Munin::Master::HTMLOld, a minimal package shell to make
munin-html modular (so it can loaded persistently in
munin-fastcgi-graph for example) without making it object oriented
yet.  The non-"old" module will feature propper object orientation
like munin-update and will have to wait until later.


Copyright (C) 2002-2009 Jimmy Olsen, Audun Ytterdal, Kjell Magne
Øierud, Nicolai Langfeldt, Linpro AS, Redpill Linpro AS and others.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; version 2 dated June,
1991.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
02110-1301 USA.

$Id$


This is the hierarchy of templates

  * munin-overview.tmpl - Overview with all groups and hosts shown (2 levels down)
    
    * munin-domainview.tmpl - all members of one domain, showing links down to each single service
      and/or sub-group

      * munin-nodeview.tmpl - two (=day, week) graphs from all plugins on the node

	* munin-serviceview.tmpl - deepest level of view, shows all 4 graphs from one timeseries

      * Zoom view - zoomable graph based on one of the other four graphs

    OR

      * munin-nodeview.tmpl - multigraph sub-level.  When multigraph sublevels end ends
           the next is a munin-serviceview.

 * Comparison pages (x4) are at the service level.  Not sure how to work multigraph into them so
   avoid it all-together.

=end comment

=cut

use warnings;
use strict;

use Exporter;

our (@ISA, @EXPORT);
@ISA    = qw(Exporter);
@EXPORT = qw(html_startup html_main get_config emit_main_index emit_comparison_template emit_group_template emit_graph_template emit_service_template emit_category_template emit_problem_template update_timestamp);

use HTML::Template;
use POSIX qw(strftime);
use Getopt::Long;
use Time::HiRes;
use File::Copy::Recursive qw(dircopy);
use IO::File;

use Munin::Master::Logger;
use Munin::Master::Utils;
use Munin::Master::HTMLConfig;

use Log::Log4perl qw( :easy );

my @times = ("day", "week", "month", "year");

my $DEBUG      = 0;
my $conffile   = "$Munin::Common::Defaults::MUNIN_CONFDIR/munin.conf";
my $do_usage   = 0;
my $do_version = 0;
my $stdout     = 0;
my $force_run_as_root = 0;
my $config;
my $limits;
my $htmltagline;
my %comparisontemplates;
my $tmpldir;
my $htmldir;
my $do_dump = 0;
my $do_fork = 1;
my $max_running=6;
my $running=0;
my $timestamp;
my $htmlconfig;

sub update_timestamp {
    # For timestamping graphs
    $timestamp = strftime("%Y-%m-%d %T%z (%Z)", localtime);
    if ($timestamp =~ /%z/) {
	# %z (numeric timezone offset) may not be available, but %Z
	# (timeszone name) seems to be universaly supported though the
	# timezone names are not really standardized.
	$timestamp = strftime("%Y-%m-%d %T%Z", localtime);
    }
    $htmltagline = "This page was generated by <a href='http://munin-monitoring.org/'>Munin</a> version ".$Munin::Common::Defaults::MUNIN_VERSION." at $timestamp";
}

sub html_startup {
    my ($args) = @_;
    local @ARGV = @{$args};
    $do_usage = 1
	unless GetOptions (
	    "host=s"    => [],
	    "service=s" => [],
	    "config=s"  => \$conffile,
	    "debug!"    => \$DEBUG,
	    "stdout!"   => \$stdout,
	    "force-run-as-root!" => \$force_run_as_root,
	    "help"      => \$do_usage,
	    "version!"  => \$do_version,
	    "dump!"     => \$do_dump,
	    "fork!"     => \$do_fork,
        );

    print_usage_and_exit() if $do_usage;
    print_version_and_exit() if $do_version;

    exit_if_run_by_super_user() unless $force_run_as_root;

    munin_readconfig_base($conffile);
    # XXX: should not need that part here, yet.
    $config = munin_readconfig_part('datafile', 0);
 
    logger_open($config->{'logdir'});
    logger_debug() if $DEBUG;

    $tmpldir = $config->{tmpldir};
    $htmldir = $config->{htmldir};

    $max_running = &munin_get($config, "max_html_jobs", $max_running);

    update_timestamp();
 
    %comparisontemplates = instanciate_comparison_templates($tmpldir);
}

sub get_config {
	my $use_cache = shift;
	# usecache should match being in a cgi ($ENV{SCRIPT_NAME})
	if ($use_cache) {
		$htmlconfig = generate_config($use_cache);
	} else {
		my $graphs_filename = $config->{dbdir} . "/graphs";
		my $graphs_filename_tmp = $graphs_filename . ".tmp." . $$;

		$config->{"#%#graphs_fh"} = new IO::File("> $graphs_filename_tmp");

		$htmlconfig = generate_config($use_cache);

		# Closing the file
    		$config->{"#%#graphs_fh"} = undef;

		# Atomic move
		rename($graphs_filename_tmp, $graphs_filename);
	}
	return $htmlconfig;
}

sub html_main {
    my $staticdir = $config->{staticdir};
    copy_web_resources($staticdir, $htmldir);

    my $configtime = Time::HiRes::time;
    get_config(0);
    my $groups = $htmlconfig;
    $configtime = sprintf("%.2f", (Time::HiRes::time - $configtime));
    INFO "[INFO] config generated ($configtime sec)";

    if (munin_get($config,"html_strategy","cron") eq "cgi"){
	INFO "[INFO] html_strategy is cgi. Skipping template generation";
	return;
    }

    my $update_time = Time::HiRes::time;
    my $lockfile = "$config->{rundir}/munin-html.lock";

    INFO "[INFO] Starting munin-html, getting lock $lockfile";

    munin_runlock($lockfile);


   # Preparing the group tree...

    if (!defined($groups) or scalar(%{$groups} eq '0')) {
	LOGCROAK "[FATAL] There is nothing to do here, since there are no nodes with any plugins.  Please refer to http://munin-monitoring.org/wiki/FAQ_no_graphs";
    };
	
    if (defined $groups->{"name"} and $groups->{"name"} eq "root") {
        $groups = $groups->{"groups"};    # root->groups
    }

    if ($do_dump) {
	print munin_dumpconfig_as_str($groups);
        exit 0;
    }
	
    generate_group_templates($groups);
    generate_category_templates($htmlconfig->{"globalcats"});
    emit_main_index($groups,$timestamp,0);
    emit_problem_template(0);

    INFO "[INFO] Releasing lock file $lockfile";

    munin_removelock("$lockfile");

    $update_time = sprintf("%.2f", (Time::HiRes::time - $update_time));

    INFO "[INFO] munin-html finished ($update_time sec)";
}

sub find_complinks{
    my($type) = @_;
    
    my @links = ();
    
    foreach my $current (qw(day week month year)) {
        my $data = {};

        if ($type eq $current) {
            $data->{'LINK'} = undef;
        } 
        else {
            $data->{'LINK'} = "comparison-$current.html";            
        }

        $data->{'NAME'} = $current;
        push(@links, $data);
    }

    return \@links;

}


sub emit_comparison_template {
    my ($key, $t, $emit_to_stdout) = @_;

    ( my $file = $key->{'filename'}) =~ s/index.html$//;

	$file .= "comparison-$t.html";
   	DEBUG "[DEBUG] Creating comparison page $file";

	# Rewrite peer urls to point to comparison-$t
	my $comparepeers = [];
	for my $peer (@{$key->{'peers'}}){
		my $comparelink = $peer->{"link"};
		next unless $comparelink; # avoid dead links

		$comparelink =~ s/index.html$/comparison-$t.html/;
		push((@$comparepeers), {"name" => $peer->{"name"}, "link" => $comparelink});
	}

    # when comparing categories, we're generating the page inside the
    # domain, but the images' urls will point inside the node itself,
    # or even worse within a category inside it. We strip out the
    # extra '../' that is used to generate a relative path which is no
    # longer valid.
    foreach my $cat(@{$key->{'comparecategories'}}) {
        foreach my $service(@{$cat->{'services'}}) {
            foreach my $node(@{$service->{'nodes'}}) {
                foreach my $imgsrc(qw(imgday imgweek imgmonth imgyear
                              cimgday cimgweek cimgmonth cimgyear
                              zoomday zoomweek zoommonth zoomyear)) {
                    next unless defined($node->{$imgsrc});
                    $node->{$imgsrc} =~ s|^\.\./\.\./(?:\.\./)?|../|;
                }
            }
        }
    }

    $comparisontemplates{$t}->param(
                                    INFO_OPTION => 'Groups on this level',
                                    NAME        => $key->{'name'},
                                    GROUPS      => $key->{'comparegroups'},
                                    PATH        => $key->{'path'},
                                    CSS_NAME    => get_css_name(),
                                    R_PATH   => $key->{'root_path'},
                                    COMPLINKS   => find_complinks($t),
                                    LARGESET    => decide_largeset($comparepeers), 
                                    PEERS       => $comparepeers,
                                    PARENT      => $key->{'path'}->[-2]->{'name'},
                                    CATEGORIES  => $key->{'comparecategories'},
                                    NCATEGORIES => $key->{'ncomparecategories'},
                                    TAGLINE     => $htmltagline,
									"COMPARISON-$t"  => 1,
									ROOTGROUPS	=> $htmlconfig->{"groups"},
									MUNIN_VERSION => $Munin::Common::Defaults::MUNIN_VERSION,
									TIMESTAMP	=> $timestamp,
									NGLOBALCATS => $htmlconfig->{"nglobalcats"},
									GLOBALCATS => $htmlconfig->{"globalcats"},
									NCRITICAL => scalar(@{$htmlconfig->{"problems"}->{"criticals"}}),
									NWARNING => scalar(@{$htmlconfig->{"problems"}->{"warnings"}}),
									NUNKNOWN => scalar(@{$htmlconfig->{"problems"}->{"unknowns"}}),
    );
    if($emit_to_stdout){
		print $comparisontemplates{$t}->output;
	} else {
		ensure_dir_exists($file);
	    open(my $FILE, '>', $file)
    	    or die "Cannot open $file for writing: $!";
	    print $FILE $comparisontemplates{$t}->output;
    	close $FILE;
	}
}


sub emit_graph_template {
    my ($key, $emit_to_stdout) = @_;

    my $graphtemplate = HTML::Template->new(
                                            filename => "$tmpldir/munin-nodeview.tmpl",
                                            die_on_bad_params => 0,
                                            global_vars       => 1,
                                            loop_context_vars => 1,
                                            filter            => sub {
                                                my $ref = shift;
                                                $$ref =~ s/URLX/URL$key->{'depth'}/g;
                                            });

    DEBUG "[DEBUG] Creating graph(nodeview) page ".$key->{filename};

    $graphtemplate->param(
                          INFO_OPTION => 'Nodes on this level',
                          GROUPS      => $key->{'groups'},
                          PATH        => $key->{'path'},
                          CSS_NAME    => get_css_name(),
                          R_PATH   => $key->{'root_path'},
                          PEERS       => $key->{'peers'},
                          LARGESET    => decide_largeset($key->{'peers'}), 
                          PARENT      => $key->{'path'}->[-2]->{'name'},
                          NAME        => $key->{'name'},
                          CATEGORIES  => $key->{'categories'},
                          NCATEGORIES => $key->{'ncategories'},
                          TAGLINE     => $htmltagline,
						  ROOTGROUPS  => $htmlconfig->{"groups"},
						  MUNIN_VERSION => $Munin::Common::Defaults::MUNIN_VERSION,
						  TIMESTAMP	=> $timestamp,
						  NGLOBALCATS => $htmlconfig->{"nglobalcats"},
						  GLOBALCATS => $htmlconfig->{"globalcats"},
									NCRITICAL => scalar(@{$htmlconfig->{"problems"}->{"criticals"}}),
									NWARNING => scalar(@{$htmlconfig->{"problems"}->{"warnings"}}),
									NUNKNOWN => scalar(@{$htmlconfig->{"problems"}->{"unknowns"}}),
                         );

    if($emit_to_stdout){
		print $graphtemplate->output;
	} else {
	    my $filename = $key->{'filename'};
		ensure_dir_exists($filename);
	    open(my $FILE, '>', $filename)
			or die "Cannot open $filename for writing: $!";
    	print $FILE $graphtemplate->output;
	    close $FILE;
	}
}

sub emit_category_template {
    my ($key, $time, $emit_to_stdout) = @_;

    my $graphtemplate = HTML::Template->new(
                                            filename => "$tmpldir/munin-categoryview.tmpl",
                                            die_on_bad_params => 0,
                                            global_vars       => 1,
                                            loop_context_vars => 1,
                                            filter            => sub {
                                                my $ref = shift;
                                                $$ref =~ s/URLX/URL/g;
                                            },
                                           );

	my $filename = $key->{'filename-' . $time};

    DEBUG "[DEBUG] Creating global category page ".$filename;

    foreach my $graphs(@{$key->{'graphs'}}) {
        foreach my $graph(@{$graphs->{'graphs'}}) {
            foreach my $imgsrc(qw(imgday imgweek imgmonth imgyear
                              cimgday cimgweek cimgmonth cimgyear
                              zoomday zoomweek zoommonth zoomyear)) {
                $graph->{$imgsrc} =~ s|^(?:\.\./)+||
            }
        }
    }

    $graphtemplate->param(
                          PATH        => $key->{'path'},
                          CSS_NAME    => get_css_name(),
                          HOST_URL    => $key->{'host_url'},
                          R_PATH      => ".",
						  "TIME".$time => 1,
                          NAME        => $key->{'name'},
                          TAGLINE     => $htmltagline,
						  ROOTGROUPS  => $htmlconfig->{"groups"},
						  MUNIN_VERSION => $Munin::Common::Defaults::MUNIN_VERSION,
						  TIMESTAMP	=> $timestamp,
						  NGLOBALCATS => $htmlconfig->{"nglobalcats"},
						  GLOBALCATS => $htmlconfig->{"globalcats"},
						  CATEGORY => $key->{"name"},
						  SERVICES => $key->{"graphs"},
						  NCRITICAL => scalar(@{$htmlconfig->{"problems"}->{"criticals"}}),
						  NWARNING => scalar(@{$htmlconfig->{"problems"}->{"warnings"}}),
						  NUNKNOWN => scalar(@{$htmlconfig->{"problems"}->{"unknowns"}}),
                         );

    if($emit_to_stdout){
		print $graphtemplate->output;
	} else {
		ensure_dir_exists($filename);
	    open(my $FILE, '>', $filename)
			or die "Cannot open $filename for writing: $!";
    	print $FILE $graphtemplate->output;
	    close $FILE;
	}
}

sub ensure_dir_exists {
    my $dirname  = shift;
    $dirname =~ s/\/[^\/]*$//;

    munin_mkdir_p($dirname, oct(755));
}

sub emit_problem_template {
    my ($emit_to_stdout) = @_;

    my $graphtemplate = HTML::Template->new(
	filename => "$tmpldir/munin-problemview.tmpl",
	die_on_bad_params => 0,
	global_vars       => 1,
	loop_context_vars => 1,
	);

	my $filename = munin_get_html_filename($config);
	$filename =~ s/index.html$/problems.html/g;

    INFO "[INFO] Creating problem page ".$filename;

    $graphtemplate->param(
                          CSS_NAME    => get_css_name(),
                          R_PATH      => ".",
                          NAME        => "Problem overview",
                          TAGLINE     => $htmltagline,
						  ROOTGROUPS  => $htmlconfig->{"groups"},
						  MUNIN_VERSION => $Munin::Common::Defaults::MUNIN_VERSION,
						  TIMESTAMP	=> $timestamp,
						  NGLOBALCATS => $htmlconfig->{"nglobalcats"},
						  GLOBALCATS => $htmlconfig->{"globalcats"},
						  CRITICAL => $htmlconfig->{"problems"}->{"criticals"},
						  WARNING => $htmlconfig->{"problems"}->{"warnings"},
						  UNKNOWN => $htmlconfig->{"problems"}->{"unknowns"},
						  NCRITICAL => scalar(@{$htmlconfig->{"problems"}->{"criticals"}}),
						  NWARNING => scalar(@{$htmlconfig->{"problems"}->{"warnings"}}),
						  NUNKNOWN => scalar(@{$htmlconfig->{"problems"}->{"unknowns"}}),
                         );

    if($emit_to_stdout){
		print $graphtemplate->output;
	} else {
		ensure_dir_exists($filename);
	    open(my $FILE, '>', $filename)
			or die "Cannot open $filename for writing: $!";
    	print $FILE $graphtemplate->output;
	    close $FILE;
	}
}


sub emit_group_template {
    my ($key, $emit_to_stdout) = @_;

    my $grouptemplate = HTML::Template->new(
	filename => "$tmpldir/munin-domainview.tmpl",
	die_on_bad_params => 0,
	global_vars       => 1,
	loop_context_vars => 1,
	filter            => sub {
	    my $ref = shift;
	    $$ref =~ s/URLX/URL$key->{'depth'}/g;
	});

    DEBUG "[DEBUG] Creating group page ".$key->{filename};

    $grouptemplate->param(
                          INFO_OPTION => 'Groups on this level',
                          GROUPS    => $key->{'groups'},
                          PATH      => $key->{'path'},
                          R_PATH => $key->{'root_path'},
                          CSS_NAME  => get_css_name(),
                          PEERS     => $key->{'peers'},
                          LARGESET  => decide_largeset($key->{'peers'}), 
                          PARENT    => $key->{'path'}->[-2]->{'name'} || "Overview",
                          COMPARE   => $key->{'compare'},
                          TAGLINE   => $htmltagline,
						  ROOTGROUPS => $htmlconfig->{"groups"},
						  MUNIN_VERSION => $Munin::Common::Defaults::MUNIN_VERSION,
						  TIMESTAMP	=> $timestamp,
						  NGLOBALCATS => $htmlconfig->{"nglobalcats"},
						  GLOBALCATS => $htmlconfig->{"globalcats"},
						  NCRITICAL => scalar(@{$htmlconfig->{"problems"}->{"criticals"}}),
						  NWARNING => scalar(@{$htmlconfig->{"problems"}->{"warnings"}}),
						  NUNKNOWN => scalar(@{$htmlconfig->{"problems"}->{"unknowns"}}),
	);
    if($emit_to_stdout){
		print $grouptemplate->output;
	} else {
    	my $filename = $key->{'filename'};
		ensure_dir_exists($filename);
    	open(my $FILE, '>', $filename)
		or die "Cannot open $filename for writing: $!";
    	print $FILE $grouptemplate->output;
	    close $FILE or die "Cannot close $filename after writing: $!";
	}
}

sub emit_zoom_template {
    my($srv, $emit_to_stdout) = @_;
    my $servicetemplate = HTML::Template->new(
                                              filename          => "$tmpldir/munin-dynazoom.tmpl",
                                              die_on_bad_params => 0,
                                              global_vars       => 1,
                                              loop_context_vars => 1
                                             );
	my $pathnodes = $srv->{'path'};
	my $peers = $srv->{'peers'};

    #remove underscores from peers and title (last path element)
    if ($peers){
        $peers = [ map { $_->{'name'} =~ s/_/ /g; $_;} @$peers ];
    }
    
    $pathnodes->[scalar(@$pathnodes) - 1]->{'pathname'} =~ s/_/ /g;
    $servicetemplate->param(
                            INFO_OPTION => 'Graphs in same category',
                            SERVICES  => [$srv],
                            PATH      => $pathnodes, 
                            PEERS     => $peers,
                            LARGESET  => decide_largeset($peers), 
                            R_PATH => $srv->{'root_path'},
                            CSS_NAME  => get_css_name(),
                            CATEGORY  => ucfirst $srv->{'category'},
                            TAGLINE   => $htmltagline,
						    ROOTGROUPS => $htmlconfig->{"groups"},
                            MUNIN_VERSION => $Munin::Common::Defaults::MUNIN_VERSION,
                            TIMESTAMP	=> $timestamp,
                            NGLOBALCATS => $htmlconfig->{"nglobalcats"},
                            GLOBALCATS => $htmlconfig->{"globalcats"},
                            NCRITICAL => scalar(@{$htmlconfig->{"problems"}->{"criticals"}}),
                            NWARNING => scalar(@{$htmlconfig->{"problems"}->{"warnings"}}),
                            NUNKNOWN => scalar(@{$htmlconfig->{"problems"}->{"unknowns"}}),
                            SHOW_ZOOM_JS => 1,
                           );

    if($emit_to_stdout){
		print $servicetemplate->output;
	} else {
		my $filename = $srv->{'filename'};
		ensure_dir_exists($filename);
        
	    DEBUG "[DEBUG] Creating service page $filename";
    	open(my $FILE, '>', $filename)
          or die "Cannot open '$filename' for writing: $!";
	    print $FILE $servicetemplate->output;
    	close $FILE or die "Cannot close '$filename' after writing: $!";
	}



}

sub emit_service_template {
	my ($srv, $emit_to_stdout) = @_;

    my $servicetemplate = HTML::Template->new(
                                              filename          => "$tmpldir/munin-serviceview.tmpl",
                                              die_on_bad_params => 0,
                                              global_vars       => 1,
                                              loop_context_vars => 1
                                             );

	my $pathnodes = $srv->{'path'};
	my $peers = $srv->{'peers'};

    #remove underscores from peers and title (last path element)
    if ($peers){
        $peers = [ map { $_->{'name'} =~ s/_/ /g; $_;} @$peers ];
    }
    
    $pathnodes->[scalar(@$pathnodes) - 1]->{'pathname'} =~ s/_/ /g;
    $servicetemplate->param(
                            INFO_OPTION => 'Graphs in same category',
                            SERVICES  => [$srv],
                            PATH      => $pathnodes, 
                            PEERS     => $peers,
                            LARGESET  => decide_largeset($peers), 
                            R_PATH => $srv->{'root_path'},
                            CSS_NAME  => get_css_name(),
                            CATEGORY  => ucfirst $srv->{'category'},
                            TAGLINE   => $htmltagline,
						    ROOTGROUPS => $htmlconfig->{"groups"},
                            MUNIN_VERSION => $Munin::Common::Defaults::MUNIN_VERSION,
                            TIMESTAMP	=> $timestamp,
                            NGLOBALCATS => $htmlconfig->{"nglobalcats"},
                            GLOBALCATS => $htmlconfig->{"globalcats"},
                            NCRITICAL => scalar(@{$htmlconfig->{"problems"}->{"criticals"}}),
                            NWARNING => scalar(@{$htmlconfig->{"problems"}->{"warnings"}}),
                            NUNKNOWN => scalar(@{$htmlconfig->{"problems"}->{"unknowns"}}),
                           );

    # No stored filename for this kind of html node.
    
	if($emit_to_stdout){
		print $servicetemplate->output;
	} else {
		my $filename = $srv->{'filename'};
		ensure_dir_exists($filename);

	    DEBUG "[DEBUG] Creating service page $filename";
    	open(my $FILE, '>', $filename)
        	or die "Cannot open '$filename' for writing: $!";
	    print $FILE $servicetemplate->output;
    	close $FILE or die "Cannot close '$filename' after writing: $!";
	}
}

sub decide_largeset {

    my ($peers) = @_;
    return scalar(@$peers) > $config->{'dropdownlimit'} ? 1 : 0;

}

sub emit_main_index {
    # Draw main index
    my ($groups, $t, $emit_to_stdout) = @_;

    my $template = HTML::Template->new(
        filename          => "$tmpldir/munin-overview.tmpl",
        die_on_bad_params => 0,
        loop_context_vars => 1,
		global_vars       => 1,
		filter            => sub {
		    my $ref = shift;
	    	$$ref =~ s/URLX/URL0/g;
		},
    );

    # FIX: this sometimes bugs:

    # HTML::Template::param() : attempt to set parameter 'groups' with
    # a scalar - parameter is not a TMPL_VAR! at
    # /usr/local/share/perl/5.10.0/Munin/Master/HTMLOld.pm line 140

    $template->param(
                    TAGLINE   => $htmltagline,
                    GROUPS    => $groups,
                    CSS_NAME  => get_css_name(),
					R_PATH => ".",
				    ROOTGROUPS => $htmlconfig->{"groups"},
			  	    MUNIN_VERSION => $Munin::Common::Defaults::MUNIN_VERSION,
					TIMESTAMP	=> $timestamp,
					NGLOBALCATS => $htmlconfig->{"nglobalcats"},
					GLOBALCATS => $htmlconfig->{"globalcats"},
					  NCRITICAL => scalar(@{$htmlconfig->{"problems"}->{"criticals"}}),
					  NWARNING => scalar(@{$htmlconfig->{"problems"}->{"warnings"}}),
					  NUNKNOWN => scalar(@{$htmlconfig->{"problems"}->{"unknowns"}}),
					
    );
	if($emit_to_stdout){
		print $template->output;
	} else {
	    my $filename = munin_get_html_filename($config);
		ensure_dir_exists($filename);

	    DEBUG "[DEBUG] Creating main index $filename";

    	open(my $FILE, '>', $filename)
        	or die "Cannot open $filename for writing: $!";
	    print $FILE $template->output;
    	close $FILE;
	}
}


sub copy_web_resources {
    my ($staticdir, $htmldir) = @_;
	unless(dircopy($staticdir, "$htmldir/static")){
		ERROR "[ERROR] Could not copy contents from $staticdir to $htmldir";
		die "[ERROR] Could not copy contents from $staticdir to $htmldir";
	}
}

sub instanciate_comparison_templates {
    my ($tmpldir) = @_;

    return (
        day => HTML::Template->new(
            filename          => "$tmpldir/munin-comparison-day.tmpl",
            die_on_bad_params => 0,
			global_vars       => 1,
            loop_context_vars => 1
        ),
        week => HTML::Template->new(
            filename          => "$tmpldir/munin-comparison-week.tmpl",
            die_on_bad_params => 0,
			global_vars       => 1,
            loop_context_vars => 1
        ),
        month => HTML::Template->new(
            filename          => "$tmpldir/munin-comparison-month.tmpl",
			global_vars       => 1,
            die_on_bad_params => 0,
            loop_context_vars => 1
        ),
        year => HTML::Template->new(
            filename          => "$tmpldir/munin-comparison-year.tmpl",
			global_vars       => 1,
            die_on_bad_params => 0,
            loop_context_vars => 1
        ));
}



sub get_css_name{
    #NOTE: this will do more in future versions. knuthaug 2009-11-15
    return "style.css";
}


sub fork_and_work {
    my ($work) = @_;

    if (!$do_fork || !$max_running) {

        # We're not forking.  Do work and return.
        DEBUG "[DEBUG] Doing work synchrnonously";
        &$work;
        return;
    }

    # Make sure we don't fork too much
    while ($running >= $max_running) {
        DEBUG
            "[DEBUG] Too many forks ($running/$max_running), wait for something to get done";
        look_for_child("block");
        --$running;
    }

    my $pid = fork();

    if (!defined $pid) {
        ERROR "[ERROR] fork failed: $!";
        die "fork failed: $!";
    }

    if ($pid == 0) {

        # This block does the real work.  Since we're forking exit
        # afterwards.

        &$work;

        # See?!

        exit 0;

    }
    else {
        ++$running;
        DEBUG "[DEBUG] Forked: $pid. Now running $running/$max_running";
        while ($running and look_for_child()) {
            --$running;
        }
    }
}

sub generate_category_templates {
	my $arr = shift || return;
	
	foreach my $key (@$arr) {
		foreach my $time (@times) {
			emit_category_template($key, $time, 0);
		}
	}
}

sub generate_group_templates {
    my $arr = shift || return;
    return unless ref($arr) eq "ARRAY";

	foreach my $key (@$arr) {
        if (defined $key and ref($key) eq "HASH") {
           	
            if (defined $key->{'ngroups'} and $key->{'ngroups'}) {
                fork_and_work(sub {generate_group_templates($key->{'groups'})});
                emit_group_template($key,0);
                
                if ($key->{'compare'}) { # Create comparison templates as well 
                    foreach my $t (@times) {
                        emit_comparison_template($key,$t,0);
                    }
                }
            }
            if (defined $key->{'ngraphs'} and $key->{'ngraphs'}) {
                emit_graph_template($key, 0);
				foreach my $category (@{$key->{"categories"}}) {
					foreach my $serv (@{$category->{"services"}}) {
						unless($serv->{"multigraph"}){
							emit_service_template($serv);
							#emit_zoom_template($serv);
						}
					}
				}
            }
 
       }
    }
}

sub print_usage_and_exit {

    print "Usage: $0 [options]

Options:
    --help		View this message.
    --debug		View debug messages.
    --version		View version information.
    --nofork            Compatibility. No effect.
    --service <service>	Compatibility. No effect.
    --host <host>	Compatibility. No effect.
    --config <file>	Use <file> as configuration file. 
			[/etc/munin/munin.conf]

";
    exit 0;
}

1;


=head1 NAME

munin-html - A program to draw html-pages on an Munin installation

=head1 SYNOPSIS

munin-html [options]

=head1 OPTIONS

=over 5

=item B<< --service <service> >>

Compatibility. No effect.

=item B<< --host <host> >>

Compatibility. No effect.

=item B<< --nofork >>

Compatibility. No effect.

=item B<< --config <file> >>

Use E<lt>fileE<gt> as configuration file. [/etc/munin/munin.conf]

=item B<< --help >>

View help message.

=item B<< --[no]debug >>

If set, view debug messages. [--nodebug]

=back

=head1 DESCRIPTION

Munin-html is a part of the package Munin, which is used in combination
with Munin's node.  Munin is a group of programs to gather data from
Munin's nodes, graph them, create html-pages, and optionally warn Nagios
about any off-limit values.

Munin-html creates the html pages.

=head1 FILES

	@@CONFDIR@@/munin.conf
	@@DBDIR@@/datafile
	@@LOGDIR@@/munin-html
	@@HTMLDIR@@/*
	@@STATEDIR@@/*

=head1 VERSION

This is munin-html version @@VERSION@@

=head1 AUTHORS

Knut Haugen, Audun Ytterdal and Jimmy Olsen.

=head1 BUGS

munin-html does, as of now, not check the syntax of the configuration file.

Please report other bugs in the bug tracker at L<http://munin-monitoring.org/>.

=head1 COPYRIGHT

Copyright (C) 2002-2009 Knut Haugen, Audun Ytterdal, and Jimmy Olsen /
Linpro AS.

This is free software; see the source for copying conditions. There is
NO warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR
PURPOSE.

This program is released under the GNU General Public License

=head1 SEE ALSO

For information on configuration options, please refer to the man page for
F<munin.conf>.

=cut

# vim:syntax=perl:ts=8
