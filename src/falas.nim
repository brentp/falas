import algorithm
import sequtils
import math
import sets
from ./falaspkg/version import falasVersion

var Version* = falasVersion

type
  Contig* = ref object
    ## a contig is a collection of sequences that have been
    ## merged. the base_count indicates the number of reads supporting
    ## the contig at each base.

    sequence*: string
    ## the assembled sequence

    support*: seq[uint32]
    ## number of reads covering each base in the contig.

    nreads*: int
    ## number of reads that contributed to this contig.
    start*: int

    when defined(debug):
      reads*: seq[string]

    names*: seq[string]
    ## names are used to track fragments. it is recommended to send only
    ## primary alignments (not supplementary). The user is responsible for sending
    ## names that assure fragment-specificity (this should be a pretty minimal burden).

  # internally used to track putative "resolvable mismatches"
  correction_site = tuple[qoff:int, toff:int, qbest:bool]
  ## a Match is a putative match. corrections are sites that were mismatched, but that had low
  ## support in either target or query indicating that they could be overwritten.
  ## `contig` tracks the contig this match was for.
  Match = tuple[matches: int, offset: int, mismatches: int, corrections:seq[correction_site], contig_i:int]

  ## a function that determines if a mismatch is "resolvable" and not counted as a mismatch
  ## if this function returns true, the puported mismatch is corrected by a voting scheme.
  resolvable_mismatch_fn* =  proc(qsup:uint32, tsup:uint32, qreads:int, treads:int): bool


proc `$`*(c:Contig): string =
  ## string representation of a contig.
  result = c.sequence
  result &= '\n'
  for i, s in c.support:
    result &= (s + 33).char

proc fastq*(c:Contig, name:string): string =
  ## a fastq-representation of a contig with the base-qualities indicating the amount of support
  ## for each base (+33)
  result = "@" & name & '\n'
  result &= c.sequence & "\n+\n"
  for s in c.support:
    result &= (s + 33).char

const unaligned* = low(int)

proc aligned*(ma: Match): bool {.inline.} =
  ## indicates whether a match is aligned.
  return ma.offset != unaligned

proc match_sort(a, b: Match): int =
  ## sort so that highest matches with lowest mismatches come first
  if a.matches == b.matches:
    if a.mismatches == b.mismatches:
      return a.corrections.len - b.corrections.len
    return a.mismatches - b.mismatches

  return b.matches - a.matches

proc len*(c:Contig): int {.inline.} =
  return c.sequence.len

proc `[]`*(c:Contig, i:int): char {.inline.} =
  return c.sequence[i]

proc resolvable_mismatch(qsup: uint32, tsup: uint32, qreads:int, treads:int): bool =
  ## default implementation to determine if we can overwrite a mismatch
  return ((qsup == 1'u32 and tsup > 6'u32 * qsup and qreads > 5) or
         (tsup == 1'u32 and qsup > 6'u32 * tsup and treads > 5))

proc trim*(c:var Contig, min_support:int=2) =
  ## trim bases in a contig that do not have at least `min_support`
  var a = 0
  while a < c.len - 1 and c.support[a] < uint32(min_support):
    a += 1
  if c.start != -1:
    c.start += a

  if a >= c.len - 1:
    c.sequence.set_len(0)
    c.support.set_len(0)
    c.nreads = 0
    return

  var b = c.len - 1
  while c.support[b] < uint32(min_support) and b > a:
    b -= 1

  if a > 0 or b <= c.len - 1:
    c.support = c.support[a..b]
    c.sequence = c.sequence[a..b]

proc slide_align*(q:Contig, t:var Contig, min_overlap:float64=0.7, max_mismatch:int=0, resolved:resolvable_mismatch_fn=resolvable_mismatch): Match =
  ## align (q)uery to (t)arget requiring a number of bases of overlap and fewer
  ## than the specified mismatches. If unaligned, the constant unaligned is returned.
  ## a negative value indicates that the query extends the target to the left.
  ## a positive value indicates the start position of the query into the reference
  ##
  ## default rule is to resolv a mismatch in q if qsupport < 3 and tsupport > 5 * qsupport
  ##
  var min_ovl = min_overlap.int
  if min_ovl < 1:
    min_ovl = int(min_overlap * min(q.len, t.len).float64)
  var omin = -(len(q) - min_ovl)
  var omax = len(t) - min_ovl
  var obest = unaligned

  var best_ma = min_ovl - 1
  var best_mm = max_mismatch + 1
  var best_correction: seq[correction_site]
  var correction = new_seq_of_cap[correction_site](4)
  var qo, to, mm, ma: int

  for o in 0..omax:
    if len(correction) != 0: correction.set_len(0)
    qo = 0
    to = o
    mm = 0
    ma = 0
    while qo < len(q) and to < len(t):
      if q[qo] != t[to]:
        if not resolved(q.support[qo], t.support[to], q.nreads, t.nreads):
          mm += 1
          if mm > max_mismatch:
            break
        else:
          correction.add((qo, to, q.support[qo] > t.support[to]))

      else:
        ma += 1

      qo += 1
      to += 1

    if mm <= max_mismatch and (ma > best_ma or ma == best_ma and mm < best_mm):
      best_ma = ma
      best_mm = mm
      obest = o
      best_correction = correction

  # skip zero as we did that above.
  for o in 1..abs(omin):
    if len(correction) != 0: correction.set_len(0)
    qo = o
    to = 0
    mm = 0
    ma = 0

    while qo < len(q) and to < len(t):
      if q[qo] != t[to]:
        if not resolved(q.support[qo], t.support[to], q.nreads, t.nreads):
          mm += 1
          if mm > max_mismatch:
            break
        else:
          correction.add((qo, to, q.support[qo] > t.support[to]))
      else:
        ma += 1

      qo += 1
      to += 1

    if mm <= max_mismatch and (ma > best_ma or ma == best_ma and mm < best_mm):
      best_ma = ma
      best_mm = mm
      obest = -o
      best_correction = correction
  return (matches:best_ma, offset:obest, mismatches:best_mm, corrections:best_correction, contig_i: -1)

proc make_contig(dna: string, start:int, support:uint32=1, name:string=""): Contig =
  ## make a contig from a sequence string.
  ## support argument is only used for testing, should be left as 1
  var bc = new_seq[uint32](dna.len)
  for i in 0..bc.high:
    bc[i] = support
  var o = Contig(sequence: dna, support:bc, nreads: int(support), start:start, names: @[name])
  when defined(debug):
      o.reads = @[dna]
  return o

proc slide_align(q: string, t:string, qstart:int=0, tstart:int=0, min_overlap:float64=50, max_mismatch:int=0, resolved:resolvable_mismatch_fn=resolvable_mismatch): Match =
  var tc = make_contig(t, tstart)
  return slide_align(make_contig(q, qstart), tc, min_overlap, max_mismatch, resolved=resolved)

proc insert*(t:var Contig, q:var Contig, m:var Match) =
  ## insert a contig and perform error correction for sites that
  ## were calculated during the matching.
  if not m.aligned: return
  var dont_overwrite = initSet[int](2)
  #if m.corrections.len > 0:
  #  stderr.write_line $m.corrections.len
  for correction in m.corrections:
    # flip the bases and change the support
    # we are setting the support below, so make sure not to overwrite these
    if correction.qbest:
      t.sequence[correction.toff] = q.sequence[correction.qoff]
      t.support[correction.toff] = q.support[correction.qoff]
    else:
      q.sequence[correction.qoff] = t.sequence[correction.toff]
      q.support[correction.qoff] = t.support[correction.toff]
    if m.offset < 0:
      dont_overwrite.incl(correction.qoff)
    else:
      dont_overwrite.incl(correction.toff)

  # in this case, we need to allocate a new string
  # offset -n
  # qqqqqqqqqqqqqqqqqq
  #           tttttttttttttttttttttttttttttttt
  # overhang is -m.offset
  if m.offset < 0:
    var tseq = new_string_of_cap(1000)
    var tsup = new_seq_of_cap[uint32](1000)

    tseq.add(q.sequence[0..<abs(m.offset)])
    tsup.add(q.support[0..<abs(m.offset)])

    tseq.add(t.sequence)
    tsup.add(t.support)

    # if qseq extends past tseq we have to add the rest to the end
    if q.len > tseq.len: # note this is comparing to the new tseq
      var d = q.len - tseq.len
      tseq.add(q.sequence[q.len-d..<q.len])
      # this gets set below so we just set to 0 here.
      tsup.set_len(tseq.len)

    # increment the support in tsup
    for i in abs(m.offset)..<q.len:
      if i in dont_overwrite: continue
      tsup[i] += q.support[i]
    t.sequence = tseq
    t.support = tsup
    t.nreads += q.nreads
    if q.start != -1 and t.start != -1:
      t.start = q.start
    elif t.start != -1:
        t.start += m.offset
    when defined(debug):
      t.reads.add(q.reads)
    t.names.add(q.names)
    return

  # off-set
  #          qqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
  # tttttttttttttttttttttttttttttttt
  var original_len = t.len
  if (m.offset + q.len) > t.len:
    t.sequence.set_len(m.offset + q.len)
    t.support.set_len(m.offset + q.len)


  for i in m.offset..<min(q.len + m.offset, t.len):
    if i in dont_overwrite: continue
    var qoff = i - m.offset
    t.support[i] += q.support[qoff]
    if i >= original_len:
      t.sequence[i] = q.sequence[qoff]
  t.nreads += q.nreads
  when defined(debug):
    t.reads.add(q.reads)
  t.names.add(q.names)
  if t.start == -1 and q.start != -1:
    t.start = q.start - m.offset
    #stderr.write_line "t.start:", t.start

proc best_match(contigs: var seq[Contig], q:Contig, min_overlap:float64=65, max_mismatch:int=0): Match =
  var matches = new_seq_of_cap[Match](2)
  for i, c in contigs:
    if c == q: continue
    # q always first to slide_align
    var ma = slide_align(q, contigs[i], min_overlap=min_overlap, max_mismatch=max_mismatch)
    if ma.aligned:
      ma.contig_i = i
      matches.add(ma)
  # didn't find a good match so add it.
  if len(matches) == 0:
    var ma:Match
    ma.offset = unaligned
    return ma

  matches.sort(match_sort)
  if matches.len > 1 and matches[0].matches == matches[1].matches and matches[0].mismatches == matches[1].mismatches:
    if contigs[matches[1].contig_i].len > contigs[matches[0].contig_i].len:
      return matches[1]
  return matches[0]


proc insert*(contigs: var seq[Contig], q:var Contig, min_overlap:float64=0.8, max_mismatch:int=0) =
  var ma = contigs.best_match(q, min_overlap=min_overlap, max_mismatch=max_mismatch)
  if ma.aligned:
    contigs[ma.contig_i].insert(q, ma)
  else:
    contigs.add(q)

proc insert*(contigs: var seq[Contig], q:string, start:int, name:string="", min_overlap:float64=0.8, max_mismatch:int=0) =
  var qc = make_contig(q, start, name=name)
  contigs.insert(qc, min_overlap=min_overlap, max_mismatch=max_mismatch)

proc frag_insert(a:var Contig, b:var Contig, min_overlap:int): bool {.inline.} =
  # insert because of evidence that a and b have at least 1 read from the same fragments.
  var m = slide_align(b, a, min_overlap=min_overlap.float64, max_mismatch=0)
  if not m.aligned:
    return false

  a.insert(b, m)
  return true

proc defrag*(contigs: var seq[Contig], min_overlap_bases:int=10): seq[Contig] =
  ## merge contigs using frament information provided in the `names` attribute. Still requires
  ## min_overlap_bases of overlap which can be a much smaller number than we require for regular
  ## insertion since we know they are from the same fragment.
  if contigs.len <= 1: return contigs
  result = newSeqOfCap[Contig](contigs.len)
  var merged = newSeqOfCap[int](4)
  for i in 0..<contigs.high:
    if i in merged: continue
    var a = contigs[i].names.toSet
    # for each other contig, check if there are any matching read names...
    for j in (i+1)..contigs.high:
      for b in contigs[j].names:
          if b in a:
            # if so, we try to insert.
            if contigs[i].frag_insert(contigs[j], min_overlap_bases):
              merged.add(j)
              a = contigs[i].names.toSet
              contigs[i].names = toSeq(a.items)
            break
    result.add(contigs[i])
  if not (contigs.high in merged):
    result.add(contigs[contigs.high])


proc combine*(contigs: var seq[Contig], max_mismatch:int=0, min_support:int=3, min_overlap:float64=0.8, again:bool=true): seq[Contig] =
  ## merge contigs. note that this modifies the contigs in-place.
  ## again is only internal and should not be changed by the user.

  # first we try to combine without trimming.
  if again:
    contigs = contigs.combine(max_mismatch, min_support=0, again=false, min_overlap=0.9)

  sort(contigs, proc(a:Contig, b:Contig): int = b.len - a.len)

  # then, we try to combine after trimming.
  result = new_seq_of_cap[Contig](len(contigs))
  var usedi = 0
  for i in 0..contigs.high:
    var c = contigs[i]
    if min_support > 0:
      c.trim(min_support=min(c.nreads, min_support))
    # the contig might be trimmed down to nothing so we take the first one that has some reads
    if c.nreads > 0 and len(c) > 40 and result.len == 0:
      result.add(c)
      usedi = i
      break
  if result.len == 0: return

  for i in 0..contigs.high:
    if i == usedi: continue
    var ci = contigs[i]
    var used = false
    if min_support > 0:
      ci.trim(min_support=min(ci.nreads, min_support))
      if ci.nreads == 0: continue

    var ma = result.best_match(ci, max_mismatch=max_mismatch, min_overlap=min_overlap)
    if min_overlap <= 1 and ma.aligned and ma.matches > int(min(ci.len, contigs[ma.contig_i].len).float64 * min_overlap):
      result[ma.contig_i].insert(ci, ma)
    elif ma.aligned and ma.matches > min_overlap.int:
      result[ma.contig_i].insert(ci, ma)
    elif ci.nreads > 0:
      result.add(ci)

when isMainModule:
  import unittest

  proc resolv_test(qsup: uint32, tsup: uint32, qreads:int, treads:int): bool =
    ## default implementation to determine if we can overwrite a mismatch
    return ((qsup < 3'u32 and tsup > 3'u32 * qsup) or
           (tsup < 3'u32 and qsup > 3'u32 * tsup))

  suite "contig":
    test "slide_align positive":
      var sa = slide_align(     "ACTGGGTACGGT",
                             "TTAACTGGGTACGGT", min_overlap=5)
      check 3 == sa.offset
      check 12 == sa.matches

    test "slide_align extend":
      check 3 == slide_align(   "ACTGGGTACGGTGGG",
                             "TTAACTGGGTACGGT", min_overlap=5).offset
    test "slide_align inside":
      check 3 == slide_align(   "ACTGGGTACG",
                             "TTAACTGGGTACGGT", min_overlap=5).offset

    test "slide_align same":
      check 0 == slide_align("TTAACTGGGTACGGT",
                             "TTAACTGGGTACGGT", min_overlap=5).offset
    test "slide_align left":
      check -1 == slide_align("ATTAACTGGGTACGGT",
                               "TTAACTGGGTACGGT", min_overlap=5).offset

      check -1 == slide_align("ATTAACTGGGTACGGT",
                               "TTAACTGGGTACGGTTTT", min_overlap=5).offset
    test "slide query contains target":
      check -1 == slide_align("ATTAACTGGGTACGGTTTGGGG",
                               "TTAACTGGGTACGGTTTG", min_overlap=5).offset

    test "min_overlap":
      check unaligned == slide_align("ATTAACTGGGTACGGTTTGGGG",
                                      "TTAACTGGGTACGGTTTG", min_overlap=50).offset

    test "corrections":
      var t = make_contig("ATTAACTGGGTACGGTTTGGGG", 0, 2)
      var q = make_contig( "TTAACTGGGXACGGTTTGG", 0, 6)

      var ma = q.slide_align(t, min_overlap=5, resolved=resolv_test)
      check ma.corrections.len == 0

      q = make_contig( "TTAACTGGGXACGGTTTGG", 0, 7)
      ma = q.slide_align(t, min_overlap=5, resolved=resolv_test)
      check ma.corrections.len == 1
      check q.sequence[ma.corrections[0].qoff] == 'X'
      check t.sequence[ma.corrections[0].toff] == 'T'
      check ma.corrections[0].qbest

      t = make_contig(    "ATTAACTGGGAACGGTTTGGGG", 0, 7)
      q = make_contig("GGAGATTAACTGGGXACGGTTTGG", 0, 2)
      ma = q.slide_align(t, min_overlap=5, resolved=resolv_test)
      check ma.corrections.len == 1
      check q.sequence[ma.corrections[0].qoff] == 'X'
      check t.sequence[ma.corrections[0].toff] == 'A'
      check (not ma.corrections[0].qbest)

    test "match sort":
      var c:seq[correction_site]
      var a:seq[Match] = @[(matches: 19, offset: 0, mismatches:0, corrections:c, contig_i:1),
                           (matches: 20, offset: 0, mismatches:1, corrections:c, contig_i:1)]
      a.sort(match_sort)
      check a[0].matches == 20
      a.add((matches:20, offset:0, mismatches:0, corrections:c, contig_i:1))
      a.sort(match_sort)
      check a[0].matches == 20
      check a[0].mismatches == 0

    test "insertion left overhang":

      var t = make_contig(    "ATTAACTGGGTACGGTTTGGGG", 3, 7)
      var q = make_contig("GGAGATTAACTGGGXACGGTTTGG", 1, 2)

      var ma = q.slide_align(t, min_overlap=5, resolved=resolv_test)
      check ma.aligned
      t.insert(q, ma)
      check t.sequence == "GGAGATTAACTGGGTACGGTTTGGGG"
      check 26 == t.sequence.len
      check 26 == t.support.len
      check t.start == 1
      #                     G      G  A  G  A  T  T  A  A  C  T  G  G  G  T  A  C  G  G  T  T  T  G  G  G  G
      check t.support == @[2'u32, 2, 2, 2, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 7, 9, 9, 9, 9, 9, 9, 9, 9, 9, 7, 7]

      t = make_contig(    "ATTAACTGGGTACGGTTTGGGG", 5, 2)
      q = make_contig("GGAGATTAACTGGGXACGGTTTGG", 0, 7)
      ma = q.slide_align(t, min_overlap=5, resolved=resolv_test)

      t.insert(q, ma)
      check t.start == 0
      check ma.aligned
      check t.sequence == "GGAGATTAACTGGGXACGGTTTGGGG"
      check t.support == @[7'u32, 7, 7, 7, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 7, 9, 9, 9, 9, 9, 9, 9, 9, 9, 2, 2]
      #q = make_contig("GGAGATTAACTGGGXACGGTTTGG", 0, 12)

      t = make_contig(    "ATTAACTGGGTAC", 3, 7)
      q = make_contig("GGAGATTAACTGGGXACGGTTTGG", 0, 2)
      ma = q.slide_align(t, min_overlap=5, resolved=resolv_test)
      check ma.aligned
      t.insert(q, ma)
      check t.sequence == "GGAGATTAACTGGGTACGGTTTGG"
      check @[2'u32, 2, 2, 2, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 7, 9, 9, 2, 2, 2, 2, 2, 2, 2] == t.support
      check t.start == 0

    test "insertion right overhang":
      var t = make_contig("GGAGATTAACTGGGXACGGTTTGG", 1, 2)
      var q = make_contig(    "ATTAACTGGGTACGGTTTGGGG", 3, 7)
      var ma = q.slide_align(t, min_overlap=5, resolved=resolv_test)
      check ma.aligned
      t.insert(q, ma)
      check t.start == 1
      #                    G      G  A  G  A  T  T  A  A  C  T  G  G  G  T  A  C  G  G  T  T  T  G  G  G  G
      check t.support == @[2'u32, 2, 2, 2, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 7, 9, 9, 9, 9, 9, 9, 9, 9, 9, 7, 7]
      check t.sequence == "GGAGATTAACTGGGTACGGTTTGGGG"

      t = make_contig("GGAGATTAACTGGGXACGGTTTGG", 90, 7)
      q = make_contig("GGAGATTAACTGGGTACGGTTTGGGG", 90, 2)
      check t.sequence.len == 24
      ma = q.slide_align(t, min_overlap=5, resolved=resolv_test)
      check ma.offset == 0
      check ma.aligned
      t.insert(q, ma)
      check t.start == 90
      check t.sequence.len == 26
      check t.sequence == "GGAGATTAACTGGGXACGGTTTGGGG"

      t = make_contig(   "GGAGATTAACTGGGXACGGTTTGG", 0, 2)
      q = make_contig("AAAGGAGATTAACTGGGTACGGTTTGGGG", 3, 7)
      ma = q.slide_align(t, min_overlap=5, resolved=resolv_test)
      check ma.offset == -3
      t.insert(q, ma)
      check t.sequence.len == q.sequence.len
      check t.sequence == "AAAGGAGATTAACTGGGTACGGTTTGGGG"
      check t.start == 3

      check t.support == @[7'u32, 7, 7, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 7, 9, 9, 9, 9, 9, 9, 9, 9, 9, 7, 7]

    test "insert with query contined in target":
      var cc:seq[correction_site]
      var tt = make_contig("CCGGGCTGGGCTT", 1, 2)
      var qq = make_contig(   "GGCTGGGCT", 1, 2)
      var match = (matches: 19, offset: 3, mismatches:0, corrections:cc, contig_i:1)
      tt.insert(qq, match)
      check tt.support == @[2'u32, 2, 2, 4, 4, 4, 4, 4, 4, 4, 4, 4, 2]


    test "frag insert":
      var tt = make_contig("CCGGGCTGGGCTT", 1, 2)
      var qq = make_contig(   "GGCTGGGCT", 1, 2)
      tt.names[0] = "AAAA"
      qq.names[0] = "BBBB"

      check (not tt.frag_insert(qq, 12))
      check tt.frag_insert(qq, 2)


    test "defrag":
      var tt = make_contig("CCGGGCTGGGCTT", 1, 2)
      var qq = make_contig(   "GGCTGGGCT", 4, 2)
      tt.names[0] = "AAAA"
      qq.names[0] = "BBBB"

      var ctgs = @[tt, qq]
      check ctgs.defrag(min_overlap_bases=2).len == 2

      qq.names[0] = tt.names[0]
      check ctgs.defrag(min_overlap_bases=2).len == 1

  
