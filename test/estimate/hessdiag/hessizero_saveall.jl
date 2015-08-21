# Compute Hessian of posterior function evaluated at x (vector)
# if verbose, display error messages, results, etc.
# 11/12/01 translated by Marco DelNegro in matlab from Frank Schorfheide's program in gauss
function hessizero_saveall!{T<:FloatingPoint}(model::AbstractModel, x::Vector{T}, YY::Matrix{T}; verbose::Bool = false)

    update!(model, x)
    
    ## index of free parameters
    para_free = [!θ.fixed for θ in model.parameters]
    fpara_free = find(para_free)
    nfree = length(fpara_free)

    npara = length(x)
    ndx = 6
    dx =  exp(-(6:2:(6+(ndx-1)*2))')
    hessdiag = zeros(npara, npara, ndx)



    # Compute Diagonal elements first
    for seli = fpara_free'
        if verbose
            println("\nHessian element: ($seli, $seli)")
        end

        for k = 1:ndx
            paradx = copy(x)
            parady = copy(x)
            paradx[seli] = paradx[seli] + dx[k]
            parady[seli] = parady[seli] - dx[k]

            fx  = posterior!(model, x, YY)
            fdx = posterior!(model, paradx, YY)
            fdy = posterior!(model, parady, YY)
            hessdiag[seli, seli, k] = -(2fx - fdx - fdy) / (dx[k])^2
        end
        
        if verbose
            values = reshape(hessdiag[seli, seli, :], 6, 1)
            println("Values: $values")
        end
    end

    # Now compute off-diagonal elements
    for i = 1:(nfree-1)
        seli = fpara_free[i]
        for j = (i+1):nfree
            selj = fpara_free[j]
            
            if verbose
                println("\nHessian element: ($seli, $selj)")
            end
            
            for k = 1:ndx
                paradx = copy(x)
                parady = copy(x)
                paradx[seli] = paradx[seli] + dx[k]
                parady[selj] = parady[selj] - dx[k]
                paradxdy = copy(paradx)
                paradxdy[selj] = paradxdy[selj] - dx[k]
                
                fx    = posterior!(model, x, YY)
                fdx   = posterior!(model, paradx, YY)
                fdy   = posterior!(model, parady, YY)
                fdxdy = posterior!(model, paradxdy, YY)
                hessdiag[seli, selj, k] = -(fx - fdx - fdy + fdxdy) / (dx[k]*dx[k])
                hessdiag[selj, seli, k] = hessdiag[seli, selj, k]
            end
            
            if verbose
                values = reshape(hessdiag[seli, selj, :], 6, 1)
                println("Values: $values")
            end
        end
    end

    return hessdiag
end