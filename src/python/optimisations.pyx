import numpy as np
cimport numpy as np
import petl.interactive as etl
import vcfnp


CHROMOSOMES = ['Pf3D7_%02d_v3' % n for n in range(1, 15)]

# constants to represent the possible outcomes when attempting to determine the inheritance for any given variant call
INHERITANCE_MISSING = 0  # genotype call is missing
INHERITANCE_FILTERED = 1  # genotype call is filtered
INHERITANCE_PARENT_MISSING = 2  # genotype is called but cannot be phased because one or both parents is missing
INHERITANCE_PARENT_FILTERED = 3  # genotype is called but cannot be phased because one or both parents is filtered
INHERITANCE_NONPARENTAL = 4  # genotype call does not correspond with either parent (i.e., mendelian error sensu strictu)
INHERITANCE_NONSEGREGATING_REF = 5  # genotype call is ref and parents both have reference allele
INHERITANCE_NONSEGREGATING_ALT = 6  # genotype call is alt and parents both have alternate allele
INHERITANCE_PARENT1 = 7  # genotype call corresponds with first parent
INHERITANCE_PARENT2 = 8  # genotype call corresponds with second parent


# functions to determine inheritance states
###########################################


def inheritance(np.ndarray[np.int8_t, ndim=2] G):
    cdef int m = G.shape[0] # number of variants
    cdef int n = G.shape[1] # number of samples
    cdef np.ndarray[np.uint8_t, ndim=2] P
    P = np.zeros((m,n), dtype='u1')
    for i in range(m):
        for j in range(n):
            # N.B., parents are *first* two samples
            P[i,j] = inheritance_state(G[i,j], G[i,0], G[i,1])
    return P


cdef int inheritance_state(int genotype_child, int genotype_parent1, int genotype_parent2):
    if genotype_child == -1:
        return INHERITANCE_MISSING
    elif genotype_child == -2:
        return INHERITANCE_FILTERED
    elif genotype_parent1 == -1 or genotype_parent2 == -1:
        return INHERITANCE_PARENT_MISSING
    elif genotype_parent1 == -2 or genotype_parent2 == -2:
        return INHERITANCE_PARENT_FILTERED
    elif genotype_child != genotype_parent1 and genotype_child != genotype_parent2:
        return INHERITANCE_NONPARENTAL
    elif genotype_child == genotype_parent1 == genotype_parent2 == 0:
        return INHERITANCE_NONSEGREGATING_REF
    elif genotype_child == genotype_parent1 == genotype_parent2 and genotype_child > 0:
        return INHERITANCE_NONSEGREGATING_ALT
    elif genotype_child == genotype_parent1:
        return INHERITANCE_PARENT1
    elif genotype_child == genotype_parent2:
        return INHERITANCE_PARENT2
    else:
        return -1 # should never be reached


# functions to calculate haplotype statistics
#############################################


def haplotypes_chrom(V, C, chrom):
    """
    Construct arrays of haplotype length and haplotype support for all variant calls.

    """

    tbl = list()
    header = 'sample', 'chrom', 'start_min', 'start_mid', 'start_max', 'stop_min', 'stop_mid', 'stop_max', 'length_min', \
             'length_mid', 'length_max', 'support', 'prv_inheritance', 'inheritance', 'nxt_inheritance'
    tbl.append(header)

    cdef int i, j, M, N, prv_idx, start_idx, stop_idx, start_min, start_mid, start_max, stop_min, stop_mid, \
        stop_max, length_min, length_mid, length_max, support, prv, cur

    samples = C.dtype.names
    C2d = vcfnp.view2d(C).view(np.recarray)

    # only deal with one chromosome, make life simpler
    flt = V.CHROM == chrom
    indices = np.nonzero(flt)[0]
    V = np.take(V, indices, axis=0)
    C2d = np.take(C2d, indices, axis=0)
    M, N = C2d.shape
    cdef np.ndarray[np.uint8_t, ndim=2] P
    P = inheritance(C2d.genotype)  # inheritance
#    print M, N

    cdef np.ndarray[np.int32_t, ndim=1] POS
    POS = V['POS']

    cdef np.ndarray[np.int32_t, ndim=2] HL
    cdef np.ndarray[np.int32_t, ndim=2] HS
    HL = np.zeros((M, N), dtype='i4') # haplotype lengths (minimum)
    HS = np.zeros((M, N), dtype='i4') # haplotype support - number of calls supporting the haplotype

    cdef np.ndarray[np.int32_t, ndim=1] previous_call_idx
    cdef np.ndarray[np.int32_t, ndim=2] haplotype_start_idxs
    cdef np.ndarray[np.int32_t, ndim=1] last_haplotype_inheritance
    previous_call_idx = np.array([-1] * N, dtype='i4') # store index of last good call
    haplotype_start_idxs = np.array([[-1, -1]] * N, dtype='i4') # store indices of haplotype start (flanking markers)
    last_haplotype_inheritance = np.array([-1] * N, dtype='i4') # store parental inheritance of upstream block

    # iterate over variants
    for i in range(M):
        # iterate over samples
        for j in range(N):
            # extract genotype call for current variant/sample
            cur = P[i, j]
            if cur == INHERITANCE_PARENT1 or cur == INHERITANCE_PARENT2: # current call is good
                # index of last good call for this sample
                prv_idx = previous_call_idx[j]
                if prv_idx < 0:
                    # this is the first good call, start a haplotype
                    haplotype_start_idxs[j] = (i, i)
                else:
                    # extract last good genotype call for current sample
                    prv = P[prv_idx, j]
                    if cur != prv:
                        # inheritance switch, haplotype has ended
                        start_min_idx, start_max_idx = tuple(haplotype_start_idxs[j])
                        stop_min_idx, stop_max_idx = prv_idx, i
                        start_min = POS[start_min_idx]
                        start_max = POS[start_max_idx]
                        start_mid = (start_max + start_min) / 2
                        stop_min = POS[stop_min_idx]
                        stop_max = POS[stop_max_idx]
                        stop_mid = (stop_max + stop_min) / 2
                        length_min = stop_min - start_max
                        length_max = stop_max - start_min
                        length_mid = stop_mid - start_mid
                        support = np.count_nonzero(P[start_max_idx:stop_min_idx+1, j] == prv)
                        # assign results
                        HL[start_max_idx:stop_min_idx+1, j] = length_min
                        HS[start_max_idx:stop_min_idx+1, j] = support
                        row = samples[j], chrom, start_min, start_mid, start_max, stop_min, stop_mid, stop_max, \
                              length_min, length_mid, length_max, support, last_haplotype_inheritance[j], prv, cur
                        tbl.append(row)
                        # start new haplotype
                        haplotype_start_idxs[j] = (prv_idx, i)
                        last_haplotype_inheritance[j] = prv
                    else:
                        # haplotype continues
                        pass
                # store last good call index
                previous_call_idx[j] = i

    # final haplotypes ending at chromosome end
    for j in range(N):
        start_min_idx, start_max_idx = tuple(haplotype_start_idxs[j])
        stop_min_idx, stop_max_idx = prv_idx, prv_idx  # nothing subsequent
        start_min = POS[start_min_idx]
        start_max = POS[start_max_idx]
        start_mid = (start_max + start_min) / 2
        stop_min = POS[stop_min_idx]
        stop_max = POS[stop_max_idx]
        stop_mid = (stop_max + stop_min) / 2
        length_min = stop_min - start_max
        length_max = stop_max - start_min
        length_mid = stop_mid - start_mid
        inherit = P[prv_idx, j]
        support = np.count_nonzero(P[start_max_idx:stop_min_idx+1, j] == inherit)
        # assign results
        HL[start_max_idx:stop_min_idx+1, j] = length_min
        HS[start_max_idx:stop_min_idx+1, j] = support
        row = samples[j], chrom, start_min, start_mid, start_max, stop_min, stop_mid, stop_max, length_min, length_mid, \
              length_max, support, last_haplotype_inheritance[j], inherit, -1
        tbl.append(row)

    return HL, HS, etl.wrap(tbl)


def haplotypes(V, C):
    stats = [haplotype_stats_chrom(V, C, chrom) for chrom in CHROMOSOMES]
    HL = np.vstack(s[0] for s in stats)
    HS = np.vstack(s[1] for s in stats)
    tbl = etl.cat(*[s[2] for s in stats])
    return HL, HS, tbl


# backwards compatibility
haplotype_stats_chrom = haplotypes_chrom
haplotype_stats = haplotypes


# functions to tabulate recombination events
############################################


def tabulate_switches_chrom(V, C, chrom):
    tbl = list()
    header = 'sample', 'chrom', 'pos', 'lpos', 'rpos', 'range', 'from', 'to'
    tbl.append(header)

    cdef int i, j, m, n, prv_idx, cur, prv

    samples = C.dtype.names
    C2d = vcfnp.view2d(C).view(np.recarray)

    # only deal with one chromosome, make life simpler
    flt = V.CHROM == chrom
    indices = np.nonzero(flt)[0]
    V, C, C2d = [np.take(X, indices, axis=0) for X in [V, C, C2d]]
    m, n = C2d.shape

    cdef np.ndarray[np.uint8_t, ndim=2] P
    P = inheritance(C2d.genotype)

    cdef np.ndarray[np.int32_t, ndim=1] POS
    POS = V['POS']

    cdef np.ndarray[np.int32_t, ndim=1] previous_call_idx
    previous_call_idx = np.array([-1] * n, dtype='i4') # store index of last good call

    # iterate over variants
    for i in range(m):
        # iterate over samples
        for j in range(n):
            # extract genotype call for current variant/sample
            cur = P[i, j]
            if cur == INHERITANCE_PARENT1 or cur == INHERITANCE_PARENT2: # current call is good
                # index of last good call for this sample
                prv_idx = previous_call_idx[j]
                if prv_idx < 0:
                    # this is the first good call
                    pass
                else:
                    # extract last good genotype call for current sample
                    prv = P[prv_idx, j]
                    if cur != prv:
                        # phase switch
                        lpos = POS[prv_idx]
                        rpos = POS[i]
                        row = samples[j], chrom, (lpos + rpos) / 2, lpos, rpos, rpos-lpos, prv, cur
                        tbl.append(row)
                    else:
                        # haplotype continues
                        pass
                # store last good call index
                previous_call_idx[j] = i

    return etl.wrap(tbl)


def tabulate_switches(V, C):
    tbls = [tabulate_switches_chrom(V, C, chrom) for chrom in CHROMOSOMES]
    return etl.cat(*tbls)


