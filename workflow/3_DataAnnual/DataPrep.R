#' ---
#' title: "DataPrep"
#' author: "Jasper Slingsby & Adam M. Wilson"
#' date: "`r format(Sys.time(), '%d %B, %Y')`"
#' output:
#'   html_document:
#'     toc: true
#'     theme: cerulean
#'     keep_md: true  
#' ---
#' 
#' 
## ----setup1,echo=F,cache=F,results='hide',message=FALSE------------------
##  Source the setup file
source("../setup.R")

#' 
#' This script assembles various environmental layers into a common 30m grid for the Cape Peninsula.  It also calculates veg age based on the fire data.
#' 
#' ## Index raster
#' Import raster of an index grid (`ig`) to spatially connect all the datasets.
## ----index---------------------------------------------------------------
ig=raster(paste0(datadir,"clean/indexgrid_landsat_30m.grd")) 

#' 
#' ## Vegetation 
#' 
## ----veg-----------------------------------------------------------------
rv=readOGR(dsn=paste0(datadir,"raw/VegLayers/Vegetation_Indigenous_Remnants"), layer="Vegetation_Indigenous_Remnants") 
#remnant veg layer - readOGR() reads shapefiles
#rv; summary(rv$National_); summary(rv$Subtype); summary(rv$Community); levels(rv@data$National_)
rv_meta=data.frame(1:length(levels(rv@data$National_)), levels(rv@data$National_)) #save VegType metadata
colnames(rv_meta)=c("ID", "code") #rename columns
write.csv(rv_meta, "data/vegtypecodes.csv", row.names=F)

# reproject to the CRS of the Landsat index grid (UTM 34S)
rv=spTransform(rv,CRS(proj4string(ig)))


#' 
#' Extract the national veg types from the veg layer into a 30m raster based on the index grid
## ----veg2,htmlcap="Land cover types aggregated to the 30m grid"----------
rvrfile="data/vegtypes_landsat_30m.tif"
if(!file.exists(rvrfile))
  rvr=rasterize(rv, ig, field=c("National_"), fun="max",file=rvrfile) #get national veg type for each cell
## read it back in and 'factorize' it
rvr=raster(rvrfile)
rvr=as.factor(rvr)
rv_meta$code=as.character(rv_meta$code)
levels(rvr)=rv_meta[levels(rvr)[[1]]$ID,]
levelplot(rvr,col.regions=rainbow(nrow(rv_meta),start=.3))

#' 
#' Count number of veg types for each cell (i.e. ID mixed cells)
## ----vegc----------------------------------------------------------------
rvcfile="data/count_vegtypes_landsat_30m.tif"
if(!file.exists(rvcfile))
  rvc=rasterize(rv, ig, field=c("National_"), fun="count",file=rvcfile) 
rvc=raster(rvcfile)

#' 
#' Are there any mixed cells?
#' 
## ------------------------------------------------------------------------
table(values(rvc))

#' 
#' ## Fire data
## ----fire1---------------------------------------------------------------
fi=readOGR(dsn=paste0(datadir,"raw/Fire"), layer="CapePenFires") #Cape Peninsula fires history layers 1962-2007
fi=spTransform(fi,CRS(proj4string(ig)))

### Extract fire history data and convert to a 30m raster
fi$STARTDATE[which(fi$STARTDATE==196201001)]=19620101#fix an anomalous date...

#Raster showing total numbers of fires in each grid cell
## note the if(!file.exists)) first checks if the file already exists so you don't rerun this everytime you run the script.
ficfile="data/fires_number_1962to2007_landsat_30m.tif"
if(!file.exists(ficfile))
    fic=rasterize(fi, ig, field=c("YEAR"), fun="count",file=ficfile) 

fic=raster(ficfile)

#' 
#' 
#' 
#' ### Rasterize fire data into annual fire maps 
## ----fire2---------------------------------------------------------------
years=sort(unique(fi$YEAR)) #get the unique list of years in which fires occurred
years=1962:2014
#years=years[years>1981] #trim to 1982 onwards (our earliest reliable Landsat data)

## first check if file already exists, if not, run this
rfifile="data/fires_annual_landsat_30m.tif"
if(!file.exists(rfifile)) {
rfi=foreach(y=years,.combine=stack,.packages="raster") %dopar% {
 #loop through years making a raster of burnt cells (1/0) for each
  ## check if there were any fires that year, if not, return zeros
  if(sum(fi$YEAR==y)==0) 
      td= raster(extent(ig),res=res(ig),vals=0)
  ## if there is >0 fires, then rasterize it to the grid
  if(sum(fi$YEAR==y)>0)
      td=rasterize(fi[which(fi$YEAR==y),],ig, field="YEAR", fun="count", background=0) 
  ## return the individual raster
  return(td)
  }
writeRaster(rfi,file=rfifile)#,options=c("COMPRESS=LZW","PREDICTOR=2"))
}

rfi=stack(rfifile)
## add year as name
names(rfi)=paste0("Fire_",years)


#' 
## ----fireplot------------------------------------------------------------
gplot(rfi[[30:40]]) + 
  geom_tile(aes(fill = as.factor(value))) +
  facet_wrap(~ variable) +
        scale_fill_manual(name="Fire Status",values = c("white", "red"),breaks=c(0,1),limits=c(0,1),labels=c("No Fire","Fire")) +
          coord_equal()+ theme(axis.ticks = element_blank(), axis.text = element_blank())

#' 
#' 
#' ### Calculate veg age from fire history
#' Now we have an object `rfi` (rasterized fires) with one band/layer for each year with 0s and 1s indicating whether that pixel burned in that year.  We can use that to calculate the time since fire by setting the year that burned to 0 and adding 1 for each subsequent year until the next fire.  
#' 
#' First let's look at one pixel's data:
#' 
## ----table1,results='asis'-----------------------------------------------
x=as.vector(rfi[551072])
x2=rbind(fire=x)
colnames(x2)=years
kable(x2)

#' 
#' 
#' So we need a function that finds the fires and counts up each year.  We'll put in years before the first fire as negatives so we can identify them later.
#' 
## ----fage----------------------------------------------------------------
fage=function(x){
  ## if there are no fires, return all negative numbers
  if(sum(x)==0){return(-1:(-length(x)))}
  if(sum(x)>0){
    ## create empty vector of veg ages
    tage=rep(NA,length(years))
    ## years with fire
    fids=which(x>0)  
    tage[fids]=0
    ## fill in years before first fire
    tage[1:fids[1]]=-1:(-fids[1])
    ## Now loop through years and count up unless there was a fire
    for(i in (fids[1]+1):length(years))
    tage[i]=ifelse((i-1)%in%fids,0,tage[i-1]+1)
return(tage)
}}

#' Now let's try that: 
## ----table2,results='asis'-----------------------------------------------
x=as.vector(rfi[551072])
x2=rbind(fire=x,age=fage(x))
colnames(x2)=years
kable(x2)

#' 
#' Now use `calc` to apply that to the full stack.
## ----fireages------------------------------------------------------------
agefile="data/ages_annual_landsat_30m.tif"
if(!file.exists(agefile))
    age=calc(rfi,fage,file=agefile,progress='text',dataType="INT1S")
age=stack(agefile)
names(age)=paste0("age_",years)
age=setZ(age,years)

#' 
## ----fireanim------------------------------------------------------------
levelplot(age[[30:40]],at=seq(0,53,len=100),col.regions=rainbow(100,start=.3),scales=list(draw=F),auto.key=F,
          main="Veld age through time",maxpixels=1e4)

#' 
#' 
#' ## NDVI Compositing
#' 
## ----fgetndvi------------------------------------------------------------
getNDVI=function(file,years,prefix){
  ndvi=stack(paste0(datadir,"raw/NDVI/",file))
  NAvalue(ndvi)=0
offs(ndvi)=-2
gain(ndvi)=.001
names(ndvi)=paste0(prefix,years)
ndvi=setZ(ndvi,years)
}

#' 
#' Now use the function to read in the data and add the relevant metadata.
## ----loadLandsat---------------------------------------------------------
l4=getNDVI(file="20140722_26dbab02_LT4_L1T_ANNUAL_GREENEST_TOA__1982-1993-0000000000-0000000000.tif",
           years=1982:1993,prefix="L4_")
l5=getNDVI(file="20140722_26dbab02_LT5_L1T_ANNUAL_GREENEST_TOA__1984-2012-0000000000-0000000000.tif",
           years=1984:2012,prefix="L5_")
l7=getNDVI(file="20140722_26dbab02_LE7_L1T_ANNUAL_GREENEST_TOA__1999-2014-0000000000-0000000000.tif",
           years=1999:2014,prefix="L7_")
l8=getNDVI(file="20140722_26dbab02_LC8_L1T_ANNUAL_GREENEST_TOA__2013-2014-0000000000-0000000000.tif",
           years=2013:2014,prefix="L8_")


#' 
#' 
#' Let's check out one of the LANDSAT objects.  Raster provides a summary by just typing the object's name:
## ------------------------------------------------------------------------
l7

#' 
#' And a plot of a few different dates:
#' 
## ----landsatplot, fig.width=7, fig.height=6------------------------------
yearind=which(getZ(l7)%in%getZ(l7)[1:5])
levelplot(l7[[yearind]],col.regions=cndvi()$col,cuts=length(cndvi()$at),at=cndvi()$at,layout=c(length(yearind),1),scales=list(draw=F),maxpixels=1e5)

#' 
#' 
#' There is some temporal overlap between sensors, let's look at that:
## ----landsateras,fig.cap="Timeline of LANDSAT data by sensor",fig.height=3----
tl=melt(list(l4=getZ(l4),l5=getZ(l5),l7=getZ(l7),l8=getZ(l8)))
xyplot(as.factor(L1)~value,data=tl,pch=16,groups=as.factor(L1),asp=.15,lwd=5,ylab="LANDSAT Satellite",xlab="Date")

#' 
#' There are several ways these data could be combined.  
#' The individual scenes could be assessed for quality (cloud contamination, etc.), 
#' sensors could be weighted by sensor quality (newer=better?).  
#' Today, we'll simply combine (stack) all the available observations for each pixel.  
#' 
## ----ndviprocess---------------------------------------------------------
nyears=1984:2014

ndvifile="data/ndvi_annual_landsat_30m.tif"
if(!file.exists(ndvifile)){

  ndvi=foreach(y=nyears,.combine=stack,.packages="raster") %dopar% {
    # find which LANDSATs have data for the desired year
    w1=lapply(
      list(l4=getZ(l4),l5=getZ(l5),l7=getZ(l7),l8=getZ(l8)),
      function(x) ifelse(y%in%x,which(y==x),NA))
    # drop LANDSATs with no data for this year
    w2=w1[!is.na(w1)]
    # make a stack with the desired year for all sensors that have data
    tndvi=mean(stack(lapply(1:length(w2),function(i) {
        print(i)
      td=get(names(w2[i]))
      return(td[[w2[i]]])
    })),na.rm=T)
    return(tndvi)
    }
  writeRaster(ndvi,file=ndvifile,overwrite=T)
}

ndvi=stack(ndvifile)
names(ndvi)=paste0("ndvi_",nyears)
ndvi=setZ(ndvi,nyears)

#' 
#' 
## ----ndviplot,fig.cap="Merged annual maximum LANDSAT NDVI"---------------
tyears=1984:2014
yearind=which(getZ(ndvi)%in%tyears)

levelplot(ndvi[[yearind]],col.regions=cndvi()$col,cuts=length(cndvi()$at),
          at=cndvi()$at,margin=F,scales=list(draw=F),
          names.attr=getZ(ndvi)[yearind],maxpixels=1e4)

#' 
#' # Data Compilation
#' 
#' ## Select domain of interest
#' Here we will define the subset of cells that we will explore further.  You can fiddle with these settings to include fewer (or more) cells.  If your computer is slow, you may want to subset this further.
#' 
## ----sdat,results='asis'-------------------------------------------------

## load data for masking
cover=raster(paste0(datadir,"clean/landcover2009_landsat_30m.gri"))

maskfile="data/mask_landsat_30m.tif"
if(!file.exists(maskfile)){
    mask=overlay(cover,fic,fun=function(x,y) x==1&y>0,filename=maskfile)
}
mask=raster(maskfile)

## load additional covariate data
tmax=raster(paste0(datadir,"clean/Tmax_jan_mean.gri"))
tmin=raster(paste0(datadir,"clean/Tmin_jul_mean.gri"))
tpi=raster(paste0(datadir,"clean/tpi500.gri"))
dem=raster(paste0(datadir,"clean/dem_landsat_30m.gri"))
janrad=raster(paste0(datadir,"clean/janrad.gri"))
julrad=raster(paste0(datadir,"clean/julrad.gri"))
aspect=raster(paste0(datadir,"clean/aspect.gri"))

### Make a dataframe of all spatial data
## Beware, this approach will only work if your data are all in identical projection/grid/etc.
maskids=which(values(mask)==1)
              
sdat=data.frame(
  id=extract(ig, maskids),
  coordinates(ig)[maskids,],
  veg=extract(rvr, maskids),
  cover=extract(cover, maskids),
  tmax=extract(tmax, maskids),
  tmin=extract(tmin, maskids),
  janrad=extract(janrad, maskids),
  julrad=extract(julrad, maskids),
  aspect=extract(aspect, maskids),
  dem=extract(dem, maskids),
  tpi=extract(tpi, maskids),
  firecount=extract(fic, maskids)
)

kable(head(sdat))

#' 
#' 
#' ## Temporally varying data
## ----tdat,results='asis'-------------------------------------------------
ftdatw="data/tdatw_annual.Rdata"
if(!file.exists(ftdatw)){
  
tdatw=data.frame(
  id=extract(ig, maskids),
  extract(age, maskids),
  extract(ndvi,maskids)
  )
save(tdatw,file=ftdatw)
}

load(ftdatw)
kable(tdatw[1:10,1:10])

#' 
#' ### Reshape temporal data
#' It's often easier to work with data in 'long' format where there is one row for each observation and another column indicating what the observation is.  Let's `melt` the data to 'long' format.
## ----tdatl,results='asis'------------------------------------------------
fmodeldata="data/modeldata_annual.Rdata"
if(!file.exists(fmodeldata)){
  
tdatl=melt(tdatw,id.var="id")
tdatln=cbind.data.frame(lab=levels(tdatl$variable),
                        do.call(rbind,strsplit(as.character(levels(tdatl$variable)),"_")))
tdatl[,c("type","year")]=tdatln[match(tdatl$variable,tdatln$lab),2:3]
tdat=dcast(tdatl,id+year~type,value.var="value")
## convert year from a factor to numeric
tdat$year=as.numeric(as.character(tdat$year))
## save both the spatial and temporal datasets
save(sdat,tdat,file=fmodeldata)
}

load(fmodeldata)
## check it out
kable(head(tdat),row.names = F)

#' 
## ----,echo=FALSE,eval=FALSE,results='hide',messages=FALSE,error=FALSE----
## ## this chunk outputs a copy of this script converted to a 'normal' R file with all the text and chunk information commented out
## purl("workflow/3_DataAnnual/DataPrep.Rmd",documentation=2,
##      output="workflow/3_DataAnnual/DataPrep.R", quiet = TRUE)

#' 
