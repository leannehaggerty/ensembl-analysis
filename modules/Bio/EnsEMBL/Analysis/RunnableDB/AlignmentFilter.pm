# Cared for by Ensembl
#
# Copyright GRL & EBI
#
# You may distribute this module under the same terms as perl itself
#
# POD documentation - main docs before the code

=pod 

=head1 NAME

Bio::EnsEMBL::Analysis::RunnableDB::AlignmentFilter

=head1 SYNOPSIS

Abstract base class of AlignmentChains and AlignmentNets

=head1 DESCRIPTION

=cut
package Bio::EnsEMBL::Analysis::RunnableDB::AlignmentFilter;

use vars qw(@ISA);
use strict;

use Bio::EnsEMBL::Analysis::RunnableDB;

use Bio::EnsEMBL::Compara::DBSQL::DBAdaptor;
use Bio::EnsEMBL::DBSQL::DBAdaptor;

use Bio::EnsEMBL::Compara::GenomicAlignBlock;
use Bio::EnsEMBL::Compara::GenomicAlignGroup;

use Bio::EnsEMBL::Utils::Exception qw(throw warning);
use Bio::EnsEMBL::Utils::Argument qw( rearrange );

@ISA = qw(Bio::EnsEMBL::Analysis::RunnableDB);

############################################################
sub new {
  my ($class,@args) = @_;
  my $self = $class->SUPER::new(@args);
 
  $self->query_DnaFrag_hash({});
  $self->target_DnaFrag_hash({});

  return $self;
}



=head2 run

  Arg [1]   : Bio::EnsEMBL::Analysis::RunnableDB
  Function  : cycles through all the runnables, calls run and pushes
  their output into the RunnableDBs output array
  Returntype: array ref
  Exceptions: none
  Example   : 

=cut



sub run{
  my ($self) = @_;
  foreach my $runnable(@{$self->runnable}){
    $runnable->run;
    my $converted_output = $self->convert_output($runnable->output);
    $self->output($converted_output);
  }
}




=head2 write_output

    Title   :   write_output
    Usage   :   $self->write_output()
    Function:   Writes contents of $self->{_output} into $self->db
    Returns :   1
    Args    :   None

=cut

sub write_output {
  my($self) = @_;

  my $compara_dbh = Bio::EnsEMBL::Compara::DBSQL::DBAdaptor->new(%{$self->COMPARA_DB});

  my @gen_al_groups;
  foreach my $chain (@{$self->output}) {
    my (@chain_aligns);

    foreach my $block (@$chain) {
      $compara_dbh->get_GenomicAlignBlockAdaptor->store($block);
      push @chain_aligns, @{$block->get_all_GenomicAligns};
    }

    # we can only create the group after storing all GenomicAligns
    # in all of the blocks in the chain
    my $group = Bio::EnsEMBL::Compara::GenomicAlignGroup->new
        (-type                => "chain",
         -genomic_align_array => \@chain_aligns);

    $compara_dbh->get_GenomicAlignGroupAdaptor->store($group);
  }
}



############################################
# cigar conversion
############################################

sub compara_cigars_from_daf_cigar {
  my ($self, $daf_cigar) = @_;

  my ($q_cigar_line, $t_cigar_line, $align_length);

  my @pieces = split(/(\d*[MDI])/, $daf_cigar);

  my ($q_counter, $t_counter) = (0,0);

  foreach my $piece ( @pieces ) {

    next if ($piece !~ /^(\d*)([MDI])$/);
    
    my $num = ($1 or 1);
    my $type = $2;
    
    if( $type eq "M" ) {
      $q_counter += $num;
      $t_counter += $num;
      
    } elsif( $type eq "D" ) {
      $q_cigar_line .= (($q_counter == 1) ? "" : $q_counter)."M";
      $q_counter = 0;
      $q_cigar_line .= (($num == 1) ? "" : $num)."D";
      $t_counter += $num;
      
    } elsif( $type eq "I" ) {
      $q_counter += $num;
      $t_cigar_line .= (($t_counter == 1) ? "" : $t_counter)."M";
      $t_counter = 0;
      $t_cigar_line .= (($num == 1) ? "" : $num)."D";
    }
    $align_length += $num;
  }

  $q_cigar_line .= (($q_counter == 1) ? "" : $q_counter)."M"
      if $q_counter;
  $t_cigar_line .= (($t_counter == 1) ? "" : $t_counter)."M"
      if $t_counter;
  
  return ($q_cigar_line, $t_cigar_line, $align_length);
}


sub daf_cigar_from_compara_cigars {
  my ($self, $q_cigar, $t_cigar) = @_;

  my (@q_pieces, @t_pieces);
  foreach my $piece (split(/(\d*[MDGI])/, $q_cigar)) {
    next if ($piece !~ /^(\d*)([MDGI])$/);

    my $num = $1; $num = 1 if $num eq "";
    my $type = $2; $type = 'D' if $type ne 'M';

    if ($num > 0) {
      push @q_pieces, { num  => $num,
                        type => $type, 
                      };
    }
  }
  foreach my $piece (split(/(\d*[MDGI])/, $t_cigar)) {
    next if ($piece !~ /^(\d*)([MDGI])$/);
    
    my $num = $1; $num = 1 if $num eq "";
    my $type = $2; $type = 'D' if $type ne 'M';

    if ($num > 0) {
      push @t_pieces, { num  => $num,
                        type => $type,
                      };
    }
  }

  my $daf_cigar = "";

  while(@q_pieces and @t_pieces) {
    # should never be left with a q piece and no target pieces, or vice versa
    my $q = shift @q_pieces;
    my $t = shift @t_pieces;

    if ($q->{num} == $t->{num}) {
      if ($q->{type} eq 'M' and $t->{type} eq 'M') {
        $daf_cigar .= ($q->{num} > 1 ? $q->{num} : "") . 'M';
      } elsif ($q->{type} eq 'M' and $t->{type} eq 'D') {
        $daf_cigar .= ($q->{num} > 1 ? $q->{num} : "") . 'I';
      } elsif ($q->{type} eq 'D' and $t->{type} eq 'M') {
        $daf_cigar .= ($q->{num} > 1 ? $q->{num} : "") . 'D';
      } else {
        # must be a delete in both seqs; warn and ignore
        warn("The following cigars have a simultaneous gap:\n" . 
             $q_cigar . "\n". 
             $t_cigar . "\n");
      }
    } elsif ($q->{num} > $t->{num}) {
      if ($q->{type} ne 'M') {
        warn("The following cigars are strange:\n" . 
             $q_cigar . "\n". 
             $t_cigar . "\n");
      }
      
      if ($t->{type} eq 'M') {
        $daf_cigar .= ($t->{num} > 1 ? $t->{num} : "") . 'M';
      } elsif ($t->{type} eq 'D') {
        $daf_cigar .= ($t->{num} > 1 ? $t->{num} : "") . 'I';
      } 

      unshift @q_pieces, { 
        type => 'M',
        num  => $q->{num} - $t->{num}, 
      };

    } else {
      # $t->{num} > $q->{num}
      if ($t->{type} ne 'M') {
        warn("The following cigars are strange:\n" . 
             $q_cigar . "\n". 
             $t_cigar . "\n");
      }
      
      if ($q->{type} eq 'M') {
        $daf_cigar .= ($q->{num} > 1 ? $q->{num} : "") . 'M';
      } elsif ($q->{type} eq 'D') {
        $daf_cigar .= ($q->{num} > 1 ? $q->{num} : "") . 'D';
      } 
      unshift @t_pieces, { 
        type => 'M',
        num  => $t->{num} - $q->{num},
      };
    } 
  }

  # final sanity checks

  if (@q_pieces or @t_pieces) {
    warn("Left with dangling pieces in the following cigars:\n" .
          $q_cigar . "\n". 
          $t_cigar . "\n");
    return undef;
  }
  
  my $last_type;
  foreach my $piece (split(/(\d*[MDI])/, $daf_cigar)) {
    next if not $piece;
    my ($type) = ($piece =~ /\d*([MDI])/);

    if (defined $last_type and
       (($last_type eq 'I' and $type eq 'D') or
        ($last_type eq 'D' and $type eq 'I'))) {

      warn("Adjacent Insert/Delete in the following cigars:\n" .
           $q_cigar . "\n". 
           $t_cigar . "\n".
           $daf_cigar . "\n");

      return undef;
    }
    $last_type = $type;
  }
  
  return $daf_cigar;
}


sub convert_output {
  my ($self, $chains_of_dafs) = @_; 

  my (@chains_of_blocks);

  foreach my $chain_of_dafs (@$chains_of_dafs) {
    my @chain_of_blocks;

    foreach my $daf (@$chain_of_dafs) {
      my ($q_cigar, $t_cigar, $al_len) = 
          $self->compara_cigars_from_daf_cigar($daf->cigar_string);

      my $q_dnafrag = $self->query_DnaFrag_hash->{$daf->seqname};
      my $t_dnafrag = $self->target_DnaFrag_hash->{$daf->hseqname};

      my $out_mlss = $self->output_MethodLinkSpeciesSet;

      my $q_genomic_align = Bio::EnsEMBL::Compara::GenomicAlign->new
          (-dnafrag        => $q_dnafrag,
           -dnafrag_start  => $daf->start,
           -dnafrag_end    => $daf->end,
           -dnafrag_strand => $daf->strand,
           -cigar_line     => $q_cigar,
           -level_id       => $daf->level_id,
           -method_link_species_set => $out_mlss);

      my $t_genomic_align = Bio::EnsEMBL::Compara::GenomicAlign->new
          (-dnafrag        => $t_dnafrag,
           -dnafrag_start  => $daf->hstart,
           -dnafrag_end    => $daf->hend,
           -dnafrag_strand => $daf->hstrand,
           -cigar_line     => $t_cigar,
           -level_id       => $daf->level_id,
           -method_link_species_set => $out_mlss);

      my $gen_al_block = Bio::EnsEMBL::Compara::GenomicAlignBlock->new
          (-genomic_align_array => [$q_genomic_align, $t_genomic_align],
           -score               => $daf->score,
           -length              => $al_len,
           -method_link_species_set => $out_mlss);

      push @chain_of_blocks, $gen_al_block;
    }

    push @chains_of_blocks, \@chain_of_blocks;
  }
    
  return \@chains_of_blocks;
}


###################################

sub query_DnaFrag_hash {
  my ($self, $val) = @_;

  if (defined $val) {
    $self->{_q_dna_frags} = $val;
  }
  
  return $self->{_q_dna_frags};
}


sub target_DnaFrag_hash {
  my ($self, $val) = @_;

  if (defined $val) {
    $self->{_t_dna_frags} = $val;
  }
  
  return $self->{_t_dna_frags};
}


sub output_MethodLinkSpeciesSet {
  my ($self, $val) = @_;

  if (defined $val) {
    $self->{_out_mlss} = $val;
  }

  return $self->{_out_mlss};
}


#################################
# common config variable holders
#################################

sub INPUT_METHOD_LINK_TYPE {
  my ($self, $type) = @_;

  if (defined $type) {
    $self->{_in_method_link_type} = $type;
  }
  
  return $self->{_in_method_link_type};
}


sub OUTPUT_METHOD_LINK_TYPE {
  my ($self, $type) = @_;

  if (defined $type) {
    $self->{_out_method_link_type} = $type;
  }
  
  return $self->{_out_method_link_type};
}


sub COMPARA_DB {
  my ($self, $db) = @_;

  if (defined $db) {
    $self->{_compara_db} = $db;
  }

  return $self->{_compara_db};

}


1;
