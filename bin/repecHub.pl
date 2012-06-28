#!/usr/bin/env perl

=head1
	Parses SRU response and creates a RePEc format.
	Written by ViP@Bielefeld_University, june 2012.
=cut

use strict;
use Data::Dumper;
use LWP::UserAgent;
use XML::Simple;
use Template;

use Catmandu::Util qw(trim);

my $tt = Template->new({ 
   #   ENCODING => 'utf8',
       INCLUDE_PATH => "../templates",
       COMPILE_DIR => '/tmp/ttc',
       STAT_TTL  => 60,
   }) ;

# example query
my $sruQuery = 'http://pub.uni-bielefeld.de/sru?version=1.1&operation=searchRetrieve&query=issn=0931-6558&maximumRecords=250';

my $modsResponse = _getSruResponse($sruQuery);
my $response_ref = _extractMods($modsResponse, 100);

$tt->process('repec.tmpl', $response_ref) || die $tt->error;

=head2 _getSruResponse
	process the REST SRU request via LWP
=cut

sub _getSruResponse {

  my ($query_str) = @_ ;   
  my $my_ua = LWP::UserAgent->new();

  $my_ua->agent('Netscape/4.75');
  $my_ua->from('agent@invalid.com');
  $my_ua->timeout(60);
  $my_ua->max_size(5000000); # max 5MB

  my  $my_request = HTTP::Request->new('GET', $query_str) ;
  my  $my_response = $my_ua->request($my_request);
  return $my_response->content ;

}


=head2  _extractMods
	function to analyze sru mods responses
	and build up a hash with that

	Arguments:  
		$mods_xml - the mods xml file
             	$limit    - maximum number of records
=cut

sub _extractMods {

   my ($mods_xml, $limit) = @_ ;
   my $xmlParser = new XML::Simple();
   utf8::upgrade ($mods_xml) ;

   my $xml = $xmlParser->XMLin($mods_xml, forcearray => [ 'record', 'subject', 'relatedItem', 'detail', 'note', 'abstract', 
                                                          'name', 'role', 'titleInfo','extent', 'identifier']);

   my $num_recs = $xml->{numberOfRecords} ;
   my %response_hash ;
   $response_hash{numrecs} = $num_recs ;

   my $i = 0 ;
   (!$limit) && ($limit = 0);

   foreach my $entry (@{$xml->{records}->{record}}){
          my $hash_ref = add_record_fields (\$entry->{recordData}) ;
          push  (@{$response_hash{records}}, $hash_ref) ;
          if ($limit > 0){
             
              if ($i >= $limit){
                 last ;
              }
          } 
          $i++ ;
   }
   return \%response_hash ;

} 


=head2  add_record_fields
  function to analyze sru mods responses
  and build up a hash with that
=cut

  sub add_record_fields {

     my ($record_ref) = @_ ;
     my %hash_ref ;
     $hash_ref{recordid} = $$record_ref->{mods}->{recordInfo}->{recordIdentifier} ;
 
     if (ref ($$record_ref->{mods}->{genre})){ 
        $hash_ref{type} = $$record_ref->{mods}->{genre}->{content} ;
     }
     else { 
	     $hash_ref{type} = $$record_ref->{mods}->{genre} ;
     }

     foreach my $title_entry (@{$$record_ref->{mods}{titleInfo}}){
        push (@{$hash_ref{title}}, $title_entry->{title}) ;
     }

     $hash_ref{publ_year} = $$record_ref->{mods}->{originInfo}->{dateIssued}->{content};
     $hash_ref{publisher} = $$record_ref->{mods}->{originInfo}->{publisher} ;

     if ($$record_ref->{mods}->{originInfo}->{edition}){
        $hash_ref{edition} = $$record_ref->{mods}->{originInfo}->{edition} ;
     }

     $hash_ref{language} = $$record_ref->{mods}->{language}->{languageTerm}->{content};

     if ($$record_ref->{mods}->{originInfo}->{place}->{placeTerm}->{content})
     {
         $hash_ref{place} = $$record_ref->{mods}->{originInfo}->{place}->{placeTerm}->{content};
     }

     foreach my $note_entry (@{$$record_ref->{mods}{note}}){
          if ($note_entry->{type} eq 'publicationStatus'){
               $hash_ref{publstatus} = $note_entry->{content} ;
          }
          elsif ($note_entry->{type} eq 'reviewedWorks'){
             if ($note_entry->{content}){
               my $temp = $note_entry->{content} ;
               $temp =~ s/au://; 
               $temp =~ s/ti// ; 
               $temp =~ tr/\n//d ;                  
               $hash_ref{reviewedwork} = $temp ;
             }
          }
          elsif ($note_entry->{type} eq 'qualityControlled'){
              $hash_ref{qualitystatus} = $note_entry->{content} ;
          }
     }

     foreach my $abstr_entry (@{$$record_ref->{mods}{abstract}}){

        if ($abstr_entry->{content}){
          push (@{$hash_ref{abstract}}, $abstr_entry->{content}) ;
        }  
     }

     my $author_ref ; 
     my $affiliation_ref ;

     foreach my $auth_entry (@{$$record_ref->{mods}{name}}){
          
          if ($$auth_entry{role}[0]{roleTerm}{content}){

             my $auth_role = $$auth_entry{role}[0]{roleTerm}{content} ;
             
              if ($auth_role eq 'reviewer'){
                   
                  $auth_role = 'author' ;
              }

             if (ref ($auth_entry->{namePart}) eq 'ARRAY'){
                 
                  $author_ref->{full} = '' ;  
                  foreach my $author_part (@{$auth_entry->{namePart}}) {
                     if ($author_part->{type} eq 'given') {
                         $author_ref->{full} = $author_ref->{full} . ', ' . $author_part->{content} ;
                         $author_ref->{given} = $author_part->{content} ;
                     }
                     elsif ($author_part->{type} eq 'family') {
                         $author_ref->{full} = $author_part->{content}  . $author_ref->{full} ;
                         $author_ref->{family} = $author_part->{content} ;
                     }
                   }
            }
            elsif ($auth_role  eq 'department'){
                push (@{$hash_ref{affiliation}} , $auth_entry->{namePart}) ;
            }
            elsif ($auth_role  eq 'project'){
                push (@{$hash_ref{project}} , $auth_entry->{namePart}) ;
            }
            elsif ($auth_role  eq 'research group'){
                push (@{$hash_ref{researchgroup}} , $auth_entry->{namePart}) ;
            }
            elsif ($auth_role  eq 'editor'){  # handling corporate editors
                push (@{$hash_ref{corporate}} , $auth_entry->{namePart}) ;
            }

            if ($author_ref) {
                $author_ref->{full} = trim ($author_ref->{full}) ;
                push (@{$hash_ref{$auth_role}}, $author_ref) ;
                $author_ref = undef ;
           }
         }
     }

      foreach my $subj_entry (@{$$record_ref->{mods}{subject}}){
          if (ref ($subj_entry->{topic}) eq 'ARRAY'){
              foreach my $subj_part (@{$subj_entry->{topic}}) {
                 push (@{$hash_ref{subject}}, $subj_part) ;
              }
          }
      }

      my $entry ;
      foreach my $rel_entry (@{$$record_ref->{mods}{relatedItem}}){    
           my $rel_type = $rel_entry->{type} ;
           foreach my $title_entry (@{$rel_entry->{titleInfo}}){ 
                if ($title_entry->{title}){
                   $entry->{title} =  $title_entry->{title} ;
                }
           }

           if (ref ($rel_entry->{location}{url}))
           {
                if ($rel_entry->{location}{url}{displayLabel}){
                   push (@{$entry->{label}}, $rel_entry->{location}{url}{displayLabel}) ;
                }
                if ($rel_entry->{location}{url}{content}){
                   push (@{$entry->{url}}, $rel_entry->{location}{url}{content}) ; 
                }
           }
           elsif ($rel_entry->{location}{url}){

                $entry->{url} = $rel_entry->{location}{url} ;  
           }
           if ($rel_entry->{accessCondition}{content}){
                $entry->{accessrestriction} = $rel_entry->{accessCondition}{content} ;
           }

           foreach my $identifier_entry (@{$rel_entry->{identifier}}){

              if ($identifier_entry->{type} ne 'other'){

                 push (@{$entry->{$identifier_entry->{type}}}, $identifier_entry->{content}) ;
              }
              else {
           
                  if ($identifier_entry->{content} =~ /MEDLINE:(.*)/){
                      push (@{$entry->{medline}},  $1)   ;
                  }
                  if ($identifier_entry->{content} =~ /arXiv:(.*)/){
                      push (@{$entry->{arxiv}},  $1)   ;
                  }
                  if ($identifier_entry->{content} =~ /INSPIRE:(.*)/){
                      push (@{$entry->{inspire}},  $1)   ;
                  }
                  elsif ($identifier_entry->{content} =~ /BiPrints:(.*)/){
                        push (@{$entry->{biprints}},  $1)   ;
                  }
              }
             }

           foreach my $page_entry (@{$rel_entry->{part}{extent}}){
                if ($page_entry->{content}){
                       $entry->{pages} = $page_entry->{content} ;
                }
                if ($page_entry->{start}){
                   $entry->{prange} .= $page_entry->{start}
                }
                if (!(ref $page_entry->{end})){
                    $entry->{prange} .=  ' - ' . $page_entry->{end} ;
                }
           }

           if ($rel_entry->{part}{detail}){
                foreach my $part_entry (@{$rel_entry->{part}{detail}}){
                if ($part_entry->{number}){
                     if ($part_entry->{type} eq 'volume'){
                        $entry->{volume} =    $part_entry->{number} ;            
                      }
                      if ($part_entry->{type} eq 'issue'){
                        $entry->{issue} =    $part_entry->{number} ; 
	     	      }
      		}		      
            }
          }

        if ($rel_entry){ 
            push  (@{$hash_ref{$rel_type}} , $entry) ; 
            $entry = {} ;
        }
    }

    return \%hash_ref ;        
}
