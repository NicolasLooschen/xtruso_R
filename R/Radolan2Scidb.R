#' Upload Radolan images to specified scidb instance
#'
#' @param scidb.conn scidb connection
#' @param scidb.array scidb target array
#' @param radolan.folder folder with RADOLAN binary files
#' @param radolan.type radolan type
#' @return list with runtime information for raster creation and upload
#' @export
Radolan2Scidb <- function(scidb.conn, scidb.array, radolan.folder, radolan.type) {

  if(missing(scidb.conn))
    stop("Need to specify a scidb connection.")

  if(missing(radolan.folder))
    stop("Need to specify a folder with RADOLAN binary files.")

  if(missing(radolan.type))
    stop("Need to specify a RADOLAN product type.")

  radolan.configuration <- ReadRadolan.getConfiguration(radolan.type)

  #get RADOLAN files from folder, check for file pattern
  radolan.files <- list.files(radolan.folder, pattern=gsub("%%time%%", "(.*)", radolan.configuration$file.pattern), full.names=TRUE)

  if(length(radolan.files) == 0)
    stop("There are no files matching the requested RADOLAN product.")

  #iterate files, upload to scidb
  runtime <- c()
  for(radolan.file in radolan.files){
    time <- Sys.time()
    #read raster
    radolan.raster <- ReadRadolanBinary(radolan.file, radolan.type)
    #upload to scidb
    if(!is.null(radolan.raster))
      Radolan2Scidb.loadRaster(scidb.conn, scidb.array, radolan.raster, removeVersions=TRUE)
    else
      message(paste("File",radolan.file,"is NULL, was not uploaded to scidb", sep=" "))
    runtime <- c(runtime, Sys.time() - time)
  }

  return(runtime)

}




#' Connect to scidb instance
#'
#' @param scidb.host scidb host
#' @param scidb.protocol scidb host
#' @param scidb.port scidb host
#' @param scidb.auth_type scidb host
#' @param scidb.user scidb host
#' @param scidb.password scidb host
#' @return scidb connection
#' @export
Radolan2Scidb.getConnection <- function(scidb.host = "localhost",
                                        scidb.protocol = "https",
                                        scidb.port,
                                        scidb.auth_type,
                                        scidb.user,
                                        scidb.password) {

  if(!"scidb" %in% installed.packages()[, "Package"])
    stop("Package scidb is not installed.")

  if(missing(scidb.port))
    stop("Need to specify a scidb port.")

  if(missing(scidb.auth_type))
    return(scidbconnect(host=scidb.host, protocol=scidb.protocol, port=scidb.port))

  if(missing(user))
    stop("Need to specify a scidb user for authentication.")

  if(missing(scidb.password))
    stop("Need to specify a scidb password for authentication.")

  #establish connection
  return(scidbconnect(host=scidb.host, protocol=scidb.protocol, port=scidb.port, auth_type=scidb.auth_type, user=scidb.user, password=scidb.password))

}


#' add scidb array
#'
#' @param scidb.conn scidbconnection
#' @param scidb.array.name name of the new scidb array
#' @param scidb.array.schema schema of the new scidb array
#' @param temp flag: create temporary array
#' @return true, if query was successful, false if an error was thrown
Radolan2Scidb.createArray <- function(scidb.conn,
                                      scidb.array.name,
                                      scidb.array.schema,
                                      temp = FALSE) {

  if(missing(scidb.conn))
    stop("Need to specify a scidb connection.")

  if(missing(scidb.array.name))
    stop("Need to specify a scidb array name.")

  if(missing(scidb.array.schema))
    stop("Need to specify a scidb array schema.")

  #build create_array request
  request.create = sprintf("create_array(%s, %s, %s)", scidb.array.name, scidb.array.schema, as.character(temp))

  #query scidb
  tryCatch({
    iquery(scidb.conn, request.create, return=FALSE)
    return(TRUE)
  }, error = function(err) {
    message(err,"\n")
    return(FALSE)
  })

}


#' remove scidb array
#'
#' @param scidb.conn scidbconnection
#' @param scidb.array.name name of the scidb array to be removed
#' @return true, if query was successful, false if an error was thrown
Radolan2Scidb.removeArray <- function(scidb.conn,
                                      scidb.array.name) {

  if(missing(scidb.conn))
    stop("Need to specify a scidb connection.")

  if(missing(scidb.array.name))
    stop("Need to specify a scidb array name")

  #build remove request
  request.remove = sprintf("remove(%s)", scidb.array.name)

  #query scidb
  tryCatch({
    iquery(scidb.conn, request.remove, return=FALSE)
    return(TRUE)
  }, error = function(err) {
    message(err,"\n")
    return(FALSE)
  })

}


#' create RADOLAN dataframe for scidb upload
#'
#' @param radolan.raster RADOLAN raster object
#' @return dataframe from input raster
Radolan2Scidb.createDataframe = function(radolan.raster) {

  #get matric from raster
  matrix <- raster::as.matrix(radolan.raster)

  #create dataframe
  df <- as.data.frame(cbind(matrix[!is.na(matrix)] , which(!is.na(matrix), arr.ind=TRUE)))
  names(df) <- c("v", "x", "y")
  df$x <- as.integer64(df$x)
  df$y <- as.integer64(df$y)

  return(df)

}


#' load RADOLAN raster to array, uploads 1-d array and uses redimension to 3-d on server
#'
#' @param scidb.conn scidbconnection
#' @param scidb.array.name name of the target scidb array
#' @param radolan.raster raster to upload
#' @return true, if upload was successful
Radolan2Scidb.loadRaster <- function(scidb.conn, scidb.array.name, radolan.raster, deleteUpload = TRUE, removeVersions=FALSE) {

  tryCatch({

    #transform raster
    df <- Radolan2Scidb.createDataframe(radolan.raster)

    #get timestamp
    radolan.timestamp <- as.double.POSIXlt(attr(radolan.raster, "timestamp"))

    #create tmp array for upload
    scidb.upload.id <- floor(runif(1, min=0, max=100000))
    scidb.upload <- paste0("radolanUpload",scidb.upload.id)
    Radolan2Scidb.createArray(scidb.conn, scidb.upload, paste0("<v:double,x:int64,y:int64> [i=1:", nrow(df), "]"), TRUE)

    #upload dataframe
    upload <- as.scidb(scidb.conn, df, scidb.upload)

    #add timestamp (apply), redimension to 3d and insert to final array
    request.redimension <- sprintf("insert(redimension(apply(%s, %s, int64(%s)), %s), %s)", scidb.upload, "t", radolan.timestamp, scidb.array.name, scidb.array.name)
    iquery(scidb.conn, request.redimension, return=FALSE)

    #remove upload array
    if(deleteUpload)
      Radolan2Scidb.removeArray(scidb.conn, scidb.upload)

    #remove old versions of target arrya
    if(removeVersions)
      Radolan2Scidb.removeVersions(scidb.conn, scidb.array.name)

    return(TRUE)

  }, error = function(err) {
    message(err,"\n")
    return(FALSE)
  })

}


#' Remove all versions of an array, except latest
#'
#' @param scidb.conn scidbconnection
#' @param scidb.array.name name of the target scidb array
Radolan2Scidb.removeVersions <- function(scidb.conn, scidb.array.name) {

  #get latest version
  version.latest <- max(iquery(scidb.conn, sprintf("versions(%s)", scidb.array.name), return=TRUE)$version_id)

  #remove previous versions
  iquery(scidb.conn, sprintf("remove_versions(%s, %s)", scidb.array.name, version.latest))

}