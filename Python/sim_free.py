import numpy as np
import time
  
def randRot(d):
    '''Get randomized rotation matrix, using Arvo 1992'''
    th = d*(np.random.rand()-0.5)*2*np.pi
    phi = np.random.rand()*2*np.pi
    z = d*np.random.rand()*2
    r = np.sqrt(z)
    Vx = np.sin(phi)*r
    Vy = np.cos(phi)*r
    Vz = np.sqrt(2-z)
    st = np.sin(th)
    ct = np.cos(th)
    Sx = Vx*ct-Vy*st
    Sy = Vx*st+Vy*ct
    
    return np.array([[-Vx*Sx+ct, -Vx*Sy+st, Vx*Vz],
                     [-Vy*Sx-st, -Vy*Sy+ct, Vy*Vz],
                     [-Vz*Sx,    -Vz*Sy,    1-z]])
    
def aaRot(axis, th):
    '''Rotation matrix about an axis by an angle'''
    x = axis[0]
    y = axis[1]
    z = axis[2]
    C = np.cos(th)
    S = np.sin(th)
    return np.array([[x**2+(1-x**2)*C, (1-C)*x*y-z*S, (1-C)*x*z+y*S],
                    [(1-C)*x*y+z*S, y**2+(1-y**2)*C, (1-C)*y*z-x*S],
                    [(1-C)*x*z-y*S, (1-C)*y*z+x*S, z**2+(1-z**2)*C]])
                    
    
def initConfig(params):
    '''Initialize DNA configuration using given params'''
    # one row per bead x 3 columns
    N = params['N']
    X = np.zeros((N,3))
    # they are evenly spaced in z, starting at z=0
    # a is inter-bead spacing, or L/(N-1)
    for i in range(N):
        X[i,2] = i*params['a']
    return X
    
def Utotal(X, params):
    '''Return total energy'''
    # vector of displacements
    dX = X[1:,:]-X[:-1,:]
    # and their lengths
    ds = np.sqrt(np.sum(dX**2,1))
    # stretching contribution to energy
    U = 0.5*params['ks']*np.sum((ds-params['a'])**2)
    # unit vector displacements
    ts = dX/ds.reshape((ds.shape[0],1))
    # and bending contribution
    U -= params['kb']*np.sum(ts[:-1,:]*ts[1:,:])
    return U
    
def sampleConfigs(nsamp, burnin, thin, params):
    '''Sample equilibruim configurations of DNA'''
    # make big 3d array
    N = params['N']
    Xs = np.zeros((nsamp, N, 3))
    # and initialize current config
    X = initConfig(params)
    U = Utotal(X, params)
    # now loop through and sample configuration space
    curind = 0
    # number since last one stored
    nsince = -burnin*thin*N
    nacc = np.array([0.,0.,0.])
    ntot = np.array([0.,0.,0.])
    
    # random x proposal distribution, based on stretchiness and stuff
    delta = 0.5*np.sqrt(2/params['ks'])
    # random rotation angle scaling
    dtheta = 0.5*np.sqrt(2/params['kb'])
    # crankshaft angle step size
    dcrank = 0.5*np.sqrt(2/params['kb'])
    
    # bookkeeping
    t0 = time.time()
    tlast = t0
    print 'Starting...'
    
    while True:
        # propose new configuration
        Xnew = np.copy(X)
        
        p = np.random.rand()
        if p < 0.33:
            # randomly perturb a handful of beads
            for k in range(5):
                i = np.random.randint(N)
                Xnew[(i+1):,:] += 2*delta*(np.random.rand(3)-0.5)
            mtype = 0
        elif p < 0.66:
            # pick random bead to perturb
            i = np.random.randint(N)
            # make global move
            R = randRot(dtheta)
            # rotate the rest of the chain. doing it this way to make it easier to
            # keep end fixed
            Xnew[(i+1):,:] = Xnew[i,:]+np.dot(Xnew[(i+1):,:]-Xnew[i,:],R)
            mtype = 1
        else:
            # pick two random beads, not the same
            i = np.random.randint(N)
            j = i
            while i == j:
                j = np.random.randint(N)
            if (i>j):
                (i,j) = (j,i)
            # get the axis between them
            axis = Xnew[j,:] - Xnew[i,:]
            axis = axis/np.sqrt(np.dot(axis,axis))
            # create random rotation matrix along that axis
            R = aaRot(axis,2*(np.random.rand()-0.5)*dcrank)
            # rotate the rest of the chain. doing it this way to make it easier to
            # keep end fixed
            Xnew[(i+1):j,:] = Xnew[i,:]+np.dot(Xnew[(i+1):j,:]-Xnew[i,:],R)
            mtype = 2
            
        # now calculate and compare energies
        Unew = Utotal(Xnew,params)
            
        
        if np.random.rand() < np.exp(U-Unew):
            # accept proposal
            X = Xnew
            U = Unew
            nacc[mtype] += 1    

        if nsince == 0:
            tlast = time.time()
            

        # do we savae current conformation or not?
        if nsince >= thin*N:
            Xs[curind,:,:] = X
            curind += 1
            nsince = 0
            if np.mod(curind,nsamp/10) == 0:
                dt = np.round(time.time() - tlast,2)
                curn = (10*curind)/nsamp
                print '['+str(10*curn) + '%] - ' + str((10-curn)*dt) + 's'
                tlast = time.time()
        
        ntot[mtype] += 1
        nsince += 1
        if curind == nsamp:
            break

    print 'Accept ratios: ' + str(np.round(nacc/ntot,2))
    
    print 'Done in ' + str(np.round(time.time()-t0)) + ' sec' 

    
    return Xs