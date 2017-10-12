#!/usr/bin/env perl

use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use Pod::Usage;
use Cwd 'abs_path';
use File::Basename;

# Align cluster sequences using MAFFT.

# check dependencies - no version check.
my $mafft_bin = "";
my $parallel_bin = "";

$mafft_bin = "mafft" if `command -v mafft;`;
$parallel_bin = "parallel" if `command -v parallel;`;

my $dep_err = 0;
foreach( $mafft_bin, $parallel_bin ){
	if($_ eq "") { print "$_ command not found.\n"; $dep_err = 1 }
}
die "Dependencies missing.\n" if $dep_err == 1;

# Version

=head1  SYNOPSIS

	AlignGeneSequences.pl -i /path/to/PIRATE.gene_families.tab -g /path/to/gff/files/

=head1 Descriptions
	
	-h|--help 			usage information
	-m|--man			man page 
	-q|--quiet			verbose off [default: on]
	-i|--input			input PIRATE.gene_families.tab file [required]
	-g|--gff			gff file directory [required]
	-o|-output			output directory [default: input file path]	
	-p|--processes		no threads/parallel processes to use [default: 2]
	-t|--threshold		percentage threshold below which clusters are excluded [default: 0]

...

=cut

# path to executing script
my $script_path = abs_path(dirname($0));

# switch off buffering
$| = 1; # turn off buffering for real time feedback.

# command line options
my $man = 0;
my $help = 0;
my $quiet = 0;
my $threads = 2; 

my $threshold = 0;

my $input_file = '';
my $gff_dir = '';
my $output_dir = '';

GetOptions(

	'help|?' 	=> \$help,
	'man' 		=> \$man,
	'quiet' 	=> \$quiet,
	'input=s' 	=> \$input_file,
	'gff=s' 	=> \$gff_dir,
	'output=s'	=> \$output_dir,
	'processes=i'	=> \$threads,
	'threshold=i'	=> \$threshold,
	
) or pod2usage(2);
pod2usage(1) if $help;
pod2usage(-verbose => 2) if $man;

print "$output_dir\n";

# expand input and output files/directories
die "Input file not found.\n" unless -f "$input_file";
$input_file = abs_path($input_file);
my $input_dir = dirname(abs_path($input_file));
if ( $output_dir eq '' ){
	$output_dir = $input_dir if $output_dir eq '';
	$output_dir = abs_path("$output_dir/pangenome_sequences");
	#mkdir $output_dir or die "Could not create output directory - $output_dir/pangenome_sequences\n" if !(-d $output_dir);  
}else{
	$output_dir =~ s/\/$//;
	$output_dir = abs_path($output_dir);
}

# chack gff directory exists.
die "GFF directory not found.\n" unless -d "$gff_dir";

# make output directory if it doesn't exist. 
unless ( -d "$output_dir" ){
	 die "could not make working directory in $output_dir\n" unless mkdir "$output_dir"; 
}

# check for mandatory input arguments
pod2usage( {-message => q{input directory is a required arguement}, -exitval => 1, -verbose => 1 } ) if $input_dir eq ''; 

# Group/Loci variables
my %loci_group; # group of loci
my %group_list; # all loci in group
my %loci_genome; # loci in genome.

my @headers = ();
my @genomes = ();
my $total_genomes = 0;
my $no_headers = 0; 

# Parse multigene/paralog clusters - store in groups hash.
open GC, "$input_file" or die "$!";
while(<GC>){
	
	my $line =$_;
	$line =~ s/\R//g;
	
	if(/^allele_name\t/){
		
		@headers = split (/\t/, $line, -1 );
		$no_headers = scalar(@headers);
		
		@genomes = @headers[18.. ($no_headers-1) ];
		$total_genomes = scalar(@genomes);		
		
	}else{
		
		# sanity check 
		die "No header line in $input_file" if scalar(@headers) == 0;
		
		my @l = split (/\t/, $line, -1 );
		
		# define group values
		my $group = $l[1];
		my $no_genomes = $l[5];		
		my $per_genomes = ($no_genomes / $total_genomes) * 100;
		
		# filter on threshold
		if ( $per_genomes >= $threshold ){
		
			# Store all loci for group
			for my $idx ( 18..(scalar(@l)-1) ){
			
				my $entry = $l[$idx];
				my $entry_genome = $headers[ $idx ];
				
				unless( $entry eq "" ){
				
					$entry =~ s/\(|\)//g;
			
					foreach my $split_entry ( split(/;|:|\//, $entry, -1) ){
				
						$loci_group { $split_entry } = $group;
						$group_list { $group } { $split_entry } = 1;
						$loci_genome { $split_entry } = $entry_genome;
					
					}								
				
				}
		
			}
		
		}
	
	}
	
}

# Feedback
my $no_groups =  scalar ( keys %group_list );
print " - number of groups : $no_groups\n" if $quiet == 0;

# Check from presence gffs for all genomes.
for my $g ( @genomes ){
	die "No gff file for $g in $gff_dir\n" unless -f "$gff_dir/$g.gff";
}

# Clear pre-existing fasta files for each group.
for my $f ( keys %group_list  ){

	my $file = "$output_dir/$f.fasta";
	if ( -f $file ){
		open F, ">$file" or die " - File ($file) would not open.\n";
		close F;
	}
	
}

# Variables
my %stored_loci;

# Extract sequence for all loci
print " - extracting sequences from gffs\n" if $quiet == 0;
for my $genome ( @genomes ){
	
	# Extract sequences and print to file.
	my $count = 0;
	my $include = 0;
	my $contig_id = "";
	my @c_seq = ();
	my %seq_store;
	
	open INPUT, "$gff_dir/$genome.gff" or die $!;
	while(<INPUT>){
	
		my $line=$_;
		chomp $line;

		# start storing sequence after fasta header.
		if($line =~ /^##FASTA/){ 
			$include = 1; 
		}
		elsif( $include == 1){
		
			# header is used as contig id.
			if($line =~ /^>(\S+)/){
			
				++$count;
				
				# Don't store on first header
				if( $count > 1 ){
					my $store_seq = join ("", @c_seq);
					$seq_store{$contig_id} = $store_seq;
				}
				
				# Set variables
				$contig_id = $1;
				@c_seq = ();
						
			}
			# sequence is stored in hash.
			elsif($line =~ /^([ATGCNatcgn]+)*/){

				# sanity check - each contig should have id
				die "Contig has no header" if $contig_id eq "" ;
			
				# store uppercase sequence.
				my $seq = $1;
				$seq = uc($seq);
				
				push(@c_seq, $seq);
		
			}else{
				print "Warning: unexpected characters in line (below) for sample $genome\n$line\n";
			}
		}
	
	}close INPUT;
	
	# Store final sequence.
	my $store_seq = join ("", @c_seq);
	$seq_store{$contig_id} = $store_seq;
	
	# Get co-ordinates and print sequences.
	open INPUT, "$gff_dir/$genome.gff" or die $!;
	while(<INPUT>){
	
		my $line = $_;
		chomp $line;
		my @line_array = split(/\t/, $line);
	
		# Variables.
		my $contig="";
		my $sta="";
		my $end="";
		my $strand="";
		my $id="";

		if( $line !~ /^##/ ){
			if( $line_array[2] eq "gene"){
			}elsif($line_array[2] eq "CDS"){

				# Set variables 
				$contig = $line_array[0];
				$sta = $line_array[3];
				$end = $line_array[4];
				my $type = $line_array[2];
		
				# Direction
				if($line_array[6] eq "+"){
					$strand="Forward";
				}elsif($line_array[6] eq "-"){
					$strand="Reverse";
				}
		
				# feature length
				my $len=(($end - $sta) + 1);
			
				# Clear variables
				$id = "";
			
				# Split info line.
				my @info = split (/;/, $line_array[8]);
				foreach( @info ){
					if ($_ =~ /ID=(.+)/){
						$id = $1;
					}
				}
				
				# Sanity check id per feature.
				die "No ID for feature in $line\n" if $id eq "";
						
				# Print to file if it matches group loci id.
				if( $loci_group{$id} ){
					
					# Get sequence from contig store.
					my $seq = substr( $seq_store{$contig}, $sta-1, $len );
					
					# Reverse complement if necessary.
					if ($strand eq "Reverse"){
						$seq = reverse($seq);
						$seq =~ tr/ATCG/TAGC/;
					}
					
					# Get group file 
					my $file_group = $loci_group{$id};
					
					# Print to file
					my $file = sprintf("%s/%s.fasta", $output_dir, $file_group );
					if ( -f $file ){
						
						open F, ">>$file" or die " - File ($file) would not open.\n";
						print F ">$id\n$seq\n";	
						close F;					
						
					}else{
					
						open F, ">$file" or die " - File ($file) would not open.\n";
						print F ">$id\n$seq\n";
						close F;
					}					
					
					# Stored sequence added to sanity checking variable.
					$stored_loci {$id} = 1;
					
				}
		
			}
			
		}elsif($line =~ /^##FASTA/){
			last;
		}
		
	}close INPUT;
	 
}

# Check all sequenced have been extracted.
for my $l_check ( keys %loci_group ){
	die "No sequence found for $l_check " unless $stored_loci {$l_check};
}

# Align aa/nucleotide sequence using mafft/PRANK in parallel - back-translate if amino acid sequence.
print " - aligning group sequences using MAFFT\n" if $quiet == 0;

# Create temp files for parallel.
my $temp = "$output_dir/temp.tab";
open TEMP, ">$temp" or die $!;
	
# Variables
my $processed = 0; 
my $increment = int( $no_groups/10 );
my $curr_increment = $increment;
my $arg_count = 0;

# set feedback message
print " - 0 % aligned" if $quiet == 0;

# batch files in parallel
for my $cluster( keys %group_list ){
	
	# Increment variables;
	++$processed;
	++$arg_count;
	
	# Print to temp file.
	print TEMP "$output_dir/$cluster.fasta\t$output_dir\n"; ## MAFFT

	# When processed = increment or all samples are processed then align the files stored in temp files. 
	if( ($arg_count == $increment ) || ( $processed == $no_groups ) ){ 
	
		close TEMP;

		# MAFFT
		`parallel -a $temp --jobs $threads --colsep '\t' perl $script_path/AAalign2nucleotide.pl {1} {2}`; # >/dev/null 2>/dev/null

		# Clear temp files.
		open TEMP, ">$temp" or die $!;
	
		# Reset variables and modify progress bar.
		$arg_count = 0; 
		if( $processed > $curr_increment ){ 
			$curr_increment += $increment;		
			print "\r - ",  int(($processed/$no_groups)*100), " % aligned" if $quiet == 0;
		}		

	}
}
close TEMP;

# Tidy up
print "\r - 100 % aligned\n" if $quiet == 0;
unlink $temp;
for my $cluster( keys %group_list ){
	unlink "$output_dir/$cluster.fasta";
}

exit