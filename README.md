## FALAS: Fragment-Aware Local Assembly for Short-reads

[![Docs](https://img.shields.io/badge/docs-latest-blue.svg)](https://brentp.github.io/falas/falas.html)


This is a very simple local (re)assembler. It uses a simple algorithm that ends up being
very flexible and fast. The underlying datastructure is a `sequence` (list) of `Contig` structs. 
When a new read is inserted into the `seq` of contigs, it is checked against each contig,
sliding the read sequence along the contig looking for a match. The read is then inserted into the best
matching contig, possibly extending it. Contigs are merged in an identical manner and the number of reads
supporting each base in the contig is tracked. It has several additional bells and whistles that make it
more useful:

1. It has a concept of "resolvable mismatches", these are cases when a read matches a contig very well at many
   sites, but at a few sites it has mismatches. These might be resolvable between reads/contigs if one contig
   has many pieces of evidence and the other has a single piece (could be due to a miscall). This allows optionally
   recovering reads with rare base-calling errors.

2. It is fragment-aware. Generally, when merging contigs, we'll want a pretty high number of bases of overlap.
   However, if we know that two contigs each contain a read from the same fragment, we can be confident they
   are on the **same haplotype** so we can merge the contigs even if their overlap is quite minimal.

3. It is not an assembler in the traditional sense. For germ-line data from a single sample, this software should
   only ever be responsible for "assembling" 2 haplotypes; there will not be any mismatches,insertions, or deletions,
   just haplotypes. This simplifies the datastructure so we can do things that are magnificently inefficient
   but still quite fast.


This is a [nim](https://github.com/nim-lang/nim) library and will be used in other projects like [indelope](https://github.com/brentp/indelope)
and other forthcoming projects. However, the concepts here-in might be useful independent of the software.

## TODO

+ [ ] for unmapped/mismapped reads, try both orientations.


### Acknowledgements

the simplified assembly approach comes from Andrew Farrell. He uses this in [rufus](https://github.com/jandrewrfarrell/RUFUS), his reference-free
*de novo* variant caller.

As far as I know, the fragment-aware addition is unique to `falas`.
