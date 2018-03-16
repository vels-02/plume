#!/bin/sh

#**************************
# Plume firmware download
#**************************

XCONF_LOG_PATH=/rdklogs/logs
XCONF_LOG_FILE_NAME=xconf.txt.0
XCONF_LOG_FILE_PATHNAME=${XCONF_LOG_PATH}/${XCONF_LOG_FILE_NAME}
XCONF_LOG_FILE=${XCONF_LOG_FILE_PATHNAME}

# Variable to check ci/prod xconf cdl
CDL_SERVER_OVERRIDE=0
REBOOT_WAIT="/tmp/.waitingreboot"
DOWNLOAD_INPROGRESS="/tmp/.downloadingfw"
deferReboot="/tmp/.deferringreboot"
NO_DOWNLOAD="/tmp/.downloadBreak"
ABORT_REBOOT="/tmp/AbortReboot"
abortReboot_count=0

CURL_PATH=/usr/bin
interface=erouter0
BIN_PATH=/bin
CURL_REQUEST=""
HTTP_CODE=/tmp/fwdl_http_code.txt
FWDL_JSON=/tmp/response.txt
codebig_enabled=$CODEBIG_ENABLE
codebig=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.CodebigSupport | grep value | cut -d ":" -f 3 | tr -d ' ' `
if [ "$codebig" == "true" ]; then
    codebig_enabled=yes
    echo "Codebig support is enabled through RFC"
    echo "Codebig support is enabled through RFC" >> $XCONF_LOG_FILE
fi

#GLOBAL DECLARATIONS
image_upg_avl=0

isPeriodicFWCheckEnabled=`syscfg get PeriodicFWCheck_Enable`
reb_window=0

echo_t()
{
	    echo "`date +"%y%m%d-%T.%6N"` $1"
}

# Function to get partner_id
# Below implementation is subjected to change when XB6 has a unified build for all syndication partners.
getPartnerId()
{
    if [ -f "/etc/device.properties" ]
    then
        partner_id=`cat /etc/device.properties | grep PARTNER_ID | cut -f2 -d=`
        if [ "$partner_id" == "" ];then
            #Assigning default partner_id as Comcast.
            #If any device want to report differently, then PARTNER_ID flag has to be updated in /etc/device.properties accordingly
            echo "comcast"
        else
            echo "$partner_id"
        fi
    else
       echo "null"
    fi
}

getRequestType()
{
     request_type=2
     if [ "$1" == "ci.xconfds.ccp.xcal.tv" ]; then
            request_type=4
     fi
     return $request_type
}


#This function will not check any other criteria other than matching current firmware and requested firmware

checkFirmwareUpgCriteria()
{
	image_upg_avl=0

	currentVersion=`cat /version.txt | grep "imagename:" | cut -d ":" -f 2`

        #Comcast signed firmware images are represented in lower case and vendor signed images are represented in upper case. 
        #In order to avoid confusion in string comparison, converting both currentVersion and firmwareVersion to lower case.
	currentVersion=`echo $currentVersion | tr '[A-Z]' '[a-z]'`
        firmwareVersion=`echo $firmwareVersion | tr '[A-Z]' '[a-z]'`
	
	echo_t "XCONF SCRIPT : CurrentVersion : $currentVersion"
        echo_t "XCONF SCRIPT : UpgradeVersion : $firmwareVersion"

        echo_t "XCONF SCRIPT : CurrentVersion : $currentVersion" >> $XCONF_LOG_FILE
        echo_t "XCONF SCRIPT : UpgradeVersion : $firmwareVersion" >> $XCONF_LOG_FILE
	
	if [ "$currentVersion" != "" ] && [ "$firmwareVersion" != "" ];then
		if [ "$currentVersion" == "$firmwareVersion" ]; then
			echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are same. No upgrade/downgrade required"
			echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are same. No upgrade/downgrade required">> $XCONF_LOG_FILE
			image_upg_avl=0
			
                        if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
			   exit
			fi
		else
			echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are different. Processing Upgrade/Downgrade"
			echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are different. Processing Upgrade/Downgrade">> $XCONF_LOG_FILE
			image_upg_avl=1
		fi
	else
		echo_t "XCONF SCRIPT : Current image ("$currentVersion") Or Requested image ("$firmwareVersion") returned NULL. No Upgrade/Downgrade"
		echo_t "XCONF SCRIPT : Current image ("$currentVersion") Or Requested image ("$firmwareVersion") returned NULL. No Upgrade/Downgrade">> $XCONF_LOG_FILE
		image_upg_avl=0

		if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
		   exit
		fi
	fi
}




#This is a temporary function added to check FirmwareUpgCriteria
#This function will not check any other criteria other than matching current firmware and requested firmware

checkFirmwareUpgCriteria_temp()
{
	image_upg_avl=0

	currentVersion=`cat /version.txt | grep "imagename:" | cut -d ":" -f 2`
	firmwareVersion=`head -n1 /tmp/response.txt | cut -d "," -f4 | cut -d ":" -f2 | cut -d '"' -f2`
	currentVersion=`echo $currentVersion | tr '[A-Z]' '[a-z]'`
	firmwareVersion=`echo $firmwareVersion | tr '[A-Z]' '[a-z]'`
	if [ "$currentVersion" != "" ] && [ "$firmwareVersion" != "" ];then
		if [ "$currentVersion" == "$firmwareVersion" ]; then
			echo "XCONF SCRIPT : Current image ("$currentVersion") and Requested imgae ("$firmwareVersion") are same. No upgrade/downgrade required"
			echo "XCONF SCRIPT : Current image ("$currentVersion") and Requested imgae ("$firmwareVersion") are same. No upgrade/downgrade required">> $XCONF_LOG_FILE
			image_upg_avl=0
		else
			echo "XCONF SCRIPT : Current image ("$currentVersion") and Requested imgae ("$firmwareVersion") are different. Processing Upgrade/Downgrade"
			echo "XCONF SCRIPT : Current image ("$currentVersion") and Requested imgae ("$firmwareVersion") are different. Processing Upgrade/Downgrade">> $XCONF_LOG_FILE
			image_upg_avl=1
		fi
	else
		echo "XCONF SCRIPT : Current image ("$currentVersion") Or Requested imgae ("$firmwareVersion") returned NULL. No Upgrade/Downgrade"
		echo "XCONF SCRIPT : Current image ("$currentVersion") Or Requested imgae ("$firmwareVersion") returned NULL. No Upgrade/Downgrade">> $XCONF_LOG_FILE
		image_upg_avl=0
	fi
}



# Check if a new image is available on the XCONF server
getFirmwareUpgDetail()
{
    # The retry count and flag are used to resend a 
    # query to the XCONF server if issues with the 
    # respose or the URL received
    xconf_retry_count=1
    retry_flag=1
    isIPv6=`ifconfig erouter0 | grep inet6 | grep -i 'Global'`

    # Set the XCONF server url read from /tmp/Xconf 
    # Determine the env from $type

    #s16 : env=`cat /tmp/Xconf | cut -d "=" -f1`
    env=$type
    xconf_url=`cat /tmp/Xconf | cut -d "=" -f2`
    
    # If an /tmp/Xconf file was not created, use the default values
    if [ ! -f /tmp/Xconf ]; then
        echo_t "XCONF SCRIPT : ERROR : /tmp/Xconf file not found! Using defaults"
        echo_t "XCONF SCRIPT : ERROR : /tmp/Xconf file not found! Using defaults" >> $XCONF_LOG_FILE
        env="PROD"
        xconf_url="https://ci.xconfds.ccp.xcal.tv/xconf/swu/stb/"
    fi

    # if xconf_url uses http, then log it
    if [ `echo "${xconf_url:0:6}" | tr '[:upper:]' '[:lower:]'` != "https:" ]; then
        echo_t "firmware download config using HTTP to $xconf_url" >> $XCONF_LOG_FILE
    fi

    echo_t "XCONF SCRIPT : env is $env"
    echo_t "XCONF SCRIPT : xconf url  is $xconf_url"

    # If interface doesnt have ipv6 address then we will force the curl to go with ipv4.
    # Otherwise we will not specify the ip address family in curl options
    if [ "$isIPv6" != "" ]; then
        addr_type=""
    else
        addr_type="-4"
    fi
    
    # Check with the XCONF server if an update is available 
    while [ $xconf_retry_count -le 3 ] && [ $retry_flag -eq 1 ]
    do

        echo_t "**RETRY is $xconf_retry_count and RETRY_FLAG is $retry_flag**" >> $XCONF_LOG_FILE
        
        # White list the Xconf server url
        #echo_t "XCONF SCRIPT : Whitelisting Xconf Server url : $xconf_url"
        #echo_t "XCONF SCRIPT : Whitelisting Xconf Server url : $xconf_url" >> $XCONF_LOG_FILE
        #/etc/whitelist.sh "$xconf_url"
        
	# Perform cleanup by deleting any previous responses
	rm -f $FWDL_JSON /tmp/XconfOutput.txt
	rm -f $HTTP_CODE
	firmwareDownloadProtocol=""
	firmwareFilename=""
	firmwareLocation=""
	firmwareVersion=""
	rebootImmediately=""
        ipv6FirmwareLocation=""
        upgradeDelay=""
       
#TODO Velu
        currentVersion=`cat /version.txt | grep "imagename:" | cut -d ":" -f 2`
		#Taking device model from /etc/device.properties
		devicemodel=$MODEL_NUM
#TODO

        devicemodel="A1A"

        if [ "$devicemodel" == "" ];then
        echo_t "XCONF SCRIPT : Device model returned NULL from /etc/device.properties. Reading it from DeviceInfo.ModelName.. " >> $XCONF_LOG_FILE
        echo_t "XCONF SCRIPT : Device model returned NULL from /etc/device.properties. Reading it from DeviceInfo.ModelName.. "
        devicemodel=`dmcli eRT getv Device.DeviceInfo.ModelName  | grep string | awk '{print $5}'`
        else
        echo_t "XCONF SCRIPT : Device model taken from /etc/device.properties " >> $XCONF_LOG_FILE
        echo_t "XCONF SCRIPT : Device model taken from /etc/device.properties "
        fi

        MAC=`ifconfig $interface  | grep HWaddr | cut -d' ' -f7`
        date=`date`
        #partnerId=$(getPartnerId)
        
        MAC="10:56:11:A8:C0:76"
		
	echo_t "XCONF SCRIPT : CURRENT VERSION : $currentVersion"
        echo_t "XCONF SCRIPT : CURRENT MAC  : $MAC"
        echo_t "XCONF SCRIPT : CURRENT DATE : $date"
    	echo_t "XCONF SCRIPT : DEVICE MODEL : $devicemodel"

        # Query the  XCONF Server, using TLS 1.2
        echo_t "Attempting TLS1.2 connection to $xconf_url " >> $XCONF_LOG_FILE
        JSONSTR='eStbMac='${MAC}'&firmwareVersion='${currentVersion}'&env='${env}'&model='${devicemodel}'&localtime='${date}'&timezone=EST05&capabilities=rebootDecoupled&capabilities=RCDL&capabilities=supportsFullHttpUrl'

        if [ "$codebig_enabled" != "yes" ]; then
            echo_t "Trying Direct Communication"
            echo_t "Trying Direct Communication" >> $XCONF_LOG_FILE
            CURL_CMD="curl --interface $interface $addr_type -w '%{http_code}\n' -d \"$JSONSTR\" -o \"$FWDL_JSON\" \"$xconf_url\" --connect-timeout 30 -m 30"
            echo_t "CURL_CMD:$CURL_CMD"
            echo_t "CURL_CMD:$CURL_CMD" >> $XCONF_LOG_FILE
            result= eval $CURL_CMD > $HTTP_CODE
            ret=$?
            HTTP_RESPONSE_CODE=$(awk -F\" '{print $1}' $HTTP_CODE)
            echo_t "Direct Communication - ret:$ret, http_code:$HTTP_RESPONSE_CODE"
            echo_t "Direct Communication - ret:$ret, http_code:$HTTP_RESPONSE_CODE" >> $XCONF_LOG_FILE
        else
            domain_name=`echo $xconf_url | cut -d / -f3`
            getRequestType $domain_name
            request_type=$?
            echo_t "Trying Codebig Communication"
            echo_t "Trying Codebig Communication" >> $XCONF_LOG_FILE
            SIGN_CMD="configparamgen $request_type \"$JSONSTR\""
            eval $SIGN_CMD > /tmp/.signedRequest
            CB_SIGNED_REQUEST=`cat /tmp/.signedRequest`
            rm -f /tmp/.signedRequest
            CURL_CMD="curl --interface $interface $addr_type -w '%{http_code}\n' --tlsv1.2 -o \"$FWDL_JSON\" \"$CB_SIGNED_REQUEST\" --connect-timeout 30 -m 30"
            echo_t "CURL_CMD:$CURL_CMD"
            echo_t "CURL_CMD:$CURL_CMD" >> $XCONF_LOG_FILE
            result= eval $CURL_CMD > $HTTP_CODE
            ret=$?
            HTTP_RESPONSE_CODE=$(awk -F\" '{print $1}' $HTTP_CODE)
            echo_t "Codebig Communication - ret:$ret, http_code:$HTTP_RESPONSE_CODE"
            echo_t "Codebig Communication - ret:$ret, http_code:$HTTP_RESPONSE_CODE" >> $XCONF_LOG_FILE
        fi

        echo_t "XCONF SCRIPT : HTTP RESPONSE CODE is $HTTP_RESPONSE_CODE"
        echo_t "XCONF SCRIPT : HTTP RESPONSE CODE is $HTTP_RESPONSE_CODE" >> $XCONF_LOG_FILE

        if [ $HTTP_RESPONSE_CODE -eq 200 ];then
            # Print the response
            echo_t "XCONF SCRIPT : Print the response -> output of $FWDL_JSON after curl execution is as below"
            cat $FWDL_JSON
            echo -e "\n"
            cat $FWDL_JSON >> $XCONF_LOG_FILE
            echo -e "\n" >> $XCONF_LOG_FILE

            retry_flag=0
			
	    OUTPUT="/tmp/XconfOutput.txt" 
            cat $FWDL_JSON | tr -d '\n' | sed 's/[{}]//g' | awk  '{n=split($0,a,","); for (i=1; i<=n; i++) print a[i]}' | sed 's/\"\:\"/\|/g' | sed -r 's/\"\:(true)($)/\|true/gI' | sed -r 's/\"\:(false)($)/\|false/gI' | sed -r 's/\"\:(null)($)/\|\1/gI' | sed -r 's/\"\:([0-9]+)($)/\|\1/g' | sed 's/[\,]/ /g' | sed 's/\"//g' > $OUTPUT
			
	    firmwareDownloadProtocol=`grep firmwareDownloadProtocol $OUTPUT  | cut -d \| -f2`


            #Velu
            firmwareDownloadProtocol="http"

	    if [ "$firmwareDownloadProtocol" == "http" ];then
		echo_t "XCONF SCRIPT : Download image from HTTP server" 
                firmwareLocation=`grep firmwareLocation $OUTPUT | cut -d \| -f2 | tr -d ' '`
            else
                echo_t "XCONF SCRIPT : Download from $firmwareDownloadProtocol server not supported, check XCONF server configurations"
                echo_t "XCONF SCRIPT : Download from $firmwareDownloadProtocol server not supported, check XCONF server configurations" >> $XCONF_LOG_FILE
                echo_t "XCONF SCRIPT : Retrying query in 2 minutes"
                echo_t "XCONF SCRIPT : Retrying query in 2 minutes" >> $XCONF_LOG_FILE
                # sleep for 2 minutes and retry
                sleep 120;

                retry_flag=1
                image_upg_avl=0

                #Increment the retry count
                xconf_retry_count=$((xconf_retry_count+1))

                continue
            fi

    	    firmwareFilename=`grep firmwareFilename $OUTPUT | cut -d \| -f2`
    	    firmwareVersion=`grep firmwareVersion $OUTPUT | cut -d \| -f2`
	    ipv6FirmwareLocation=`grep ipv6FirmwareLocation  $OUTPUT | cut -d \| -f2 | tr -d ' '`
	    upgradeDelay=`grep upgradeDelay $OUTPUT | cut -d \| -f2`
            rebootImmediately=`grep rebootImmediately $OUTPUT | cut -d \| -f2`     
                                    
    	    echo_t "XCONF SCRIPT : Protocol :"$firmwareDownloadProtocol
    	    echo_t "XCONF SCRIPT : Filename :"$firmwareFilename
    	    echo_t "XCONF SCRIPT : Location :"$firmwareLocation
    	    echo_t "XCONF SCRIPT : Version  :"$firmwareVersion
    	    echo_t "XCONF SCRIPT : Reboot   :"$rebootImmediately
	
            if [ "X"$firmwareLocation = "X" ];then
                echo_t "XCONF SCRIPT : No URL received in $FWDL_JSON" >> $XCONF_LOG_FILE
                retry_flag=1
                image_upg_avl=0

                #Increment the retry count
                xconf_retry_count=$((xconf_retry_count+1))

            else
                echo "$firmwareLocation" > /tmp/.xconfssrdownloadurl
           	# Check if a newer version was returned in the response
            # If image_upg_avl = 0, retry reconnecting with XCONf in next window
            # If image_upg_avl = 1, download new firmware
			# if CDL_SERVER_OVERRIDE = 1, considering as ci-xconf communication. Will call checkFirmwareUpgCriteria_temp() and not checking PROD imagename conventions
               
			 	if [ $CDL_SERVER_OVERRIDE -eq 0 ];then  
					checkFirmwareUpgCriteria  
				else
					checkFirmwareUpgCriteria_temp
				fi

			fi
		

        # If a response code of 404 was received, error
	elif [ $HTTP_RESPONSE_CODE -eq 404 ]; then 
        	retry_flag=0
           	image_upg_avl=0
        echo_t "XCONF SCRIPT : Response code received is 404" >> $XCONF_LOG_FILE 
		
                if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
		   exit
		fi
        # If a response code of 0 was received, the server is unreachable
        # Try reconnecting
        else
            echo_t "XCONF SCRIPT : Response code is $HTTP_RESPONSE_CODE, sleeping for 2 minutes and retrying" >> $XCONF_LOG_FILE
            # sleep for 2 minutes and retry
            sleep 120;

            retry_flag=1
            image_upg_avl=0

            #Increment the retry count
            xconf_retry_count=$((xconf_retry_count+1))

        fi

    done

    # If retry for 3 times done and image is not available, then exit
    # Cron scheduled job will be triggered later
    if [ $xconf_retry_count -eq 4 ] && [ $image_upg_avl -eq 0 ]
    then
        echo_t "XCONF SCRIPT : Retry limit to connect with XCONF server reached, so exit" 
        if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
	   exit
	fi
    fi
}

calcRandTime()
{
    rand_hr=0
    rand_min=0
    rand_sec=0

    # Calculate random min
    rand_min=`awk -v min=0 -v max=59 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

    # Calculate random second
    rand_sec=`awk -v min=0 -v max=59 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

    # Extract maintenance window start and end time
    start_time=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeStartTime | grep "value:" | cut -d ":" -f 3 | tr -d ' '`
    end_time=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeEndTime | grep "value:" | cut -d ":" -f 3 | tr -d ' '`

    if [ "$start_time" = "$end_time" ]
    then
        echo_t "XCONF SCRIPT : Start time can not be equal to end time" >> $XCONF_LOG_FILE
        echo_t "XCONF SCRIPT : Resetting values to default" >> $XCONF_LOG_FILE
        dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeStartTime string "3600"
        dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeEndTime string "14400"
        start_time=3600
        end_time=14400
    fi

    echo_t "XCONF SCRIPT : Firmware upgrade start time : $start_time" >> $XCONF_LOG_FILE
    echo_t "XCONF SCRIPT : Firmware upgrade end time : $end_time" >> $XCONF_LOG_FILE

    #
    # Generate time to check for update
    #
    if [ $1 -eq '1' ]; then
        
        echo_t "XCONF SCRIPT : Check Update time being calculated within 24 hrs."
        echo_t "XCONF SCRIPT : Check Update time being calculated within 24 hrs." >> $XCONF_LOG_FILE

        # Calculate random hour
        # The max random time can be 23:59:59
        rand_hr=`awk -v min=0 -v max=23 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

        echo_t "XCONF SCRIPT : Time Generated : $rand_hr hr $rand_min min $rand_sec sec"
        min_to_sleep=$(($rand_hr*60 + $rand_min))
        sec_to_sleep=$(($min_to_sleep*60 + $rand_sec))

        printf "`date +"%y%m%d-%T.%6N"` XCONF SCRIPT : Checking update with XCONF server at \t";
        # date -d "$min_to_sleep minutes" +'%H:%M:%S'
        date -d @"$(( `date +%s`+$sec_to_sleep ))"

        date_upgch_part="$(( `date +%s`+$sec_to_sleep ))"
        date_upgch_final=`date -d @"$date_upgch_part"`

        echo_t "Checking update on $date_upgch_final" >> $XCONF_LOG_FILE

    fi

    #
    # Generate time to downlaod HTTP image
    # device reboot time 
    #
    if [ $2 -eq '1' ]; then
       
        if [ "$3" == "r" ]; then
            echo_t "XCONF SCRIPT : Device reboot time being calculated in maintenance window"
            echo_t "XCONF SCRIPT : Device reboot time being calculated in maintenance window" >> $XCONF_LOG_FILE
        fi

        if [ "$start_time" -gt "$end_time" ]
        then
            start_time=$(($start_time-86400))
        fi

        #Calculate random value
        random_time=`awk -v min=$start_time -v max=$end_time 'BEGIN{srand(); print int(min+rand()*(max-min+1))}'`

        if [ $random_time -le 0 ]
        then
            random_time=$((random_time+86400))
        fi
        random_time_in_sec=$random_time

        # Calculate random second
        rand_sec=$((random_time%60))

        # Calculate random min
        random_time=$((random_time/60))
        rand_min=$((random_time%60))

        # Calculate random hour
        random_time=$((random_time/60))
        rand_hr=$((random_time%60))

        echo_t "XCONF SCRIPT : Time Generated : $rand_hr hr $rand_min min $rand_sec sec" >> $XCONF_LOG_FILE

        # Get current time
        if [ "$UTC_ENABLE" == "true" ]
        then
            cur_hr=`LTime H`
            cur_min=`LTime M`
            cur_sec=`date +"%S"`
        else
            cur_hr=`date +"%H"`
            cur_min=`date +"%M"`
            cur_sec=`date +"%S"`
        fi
        echo_t "XCONF SCRIPT : Current Local Time: $cur_hr hr $cur_min min $cur_sec sec" >> $XCONF_LOG_FILE

        curr_hr_in_sec=$((cur_hr*60*60))
        curr_min_in_sec=$((cur_min*60))
        curr_time_in_sec=$((curr_hr_in_sec+curr_min_in_sec+cur_sec))
        echo_t "XCONF SCRIPT : Current Time in secs: $curr_time_in_sec sec" >> $XCONF_LOG_FILE

        if [ $curr_time_in_sec -le $random_time_in_sec ]
        then
            sec_to_sleep=$((random_time_in_sec-curr_time_in_sec))
        else
            sec_to_12=$((86400-curr_time_in_sec))
            sec_to_sleep=$((sec_to_12+random_time_in_sec))
        fi

        time=$(( `date +%s`+$sec_to_sleep ))
        date_final=`date -d @${time} +"%T"`

        echo_t "Action on $date_final"
        echo_t "Action on $date_final" >> $XCONF_LOG_FILE
        touch $REBOOT_WAIT

    fi

    echo_t "XCONF SCRIPT : SLEEPING FOR $min_to_sleep minutes or $sec_to_sleep seconds"
    echo_t "XCONF SCRIPT : SLEEPING FOR $min_to_sleep minutes or $sec_to_sleep seconds" >> $XCONF_LOG_FILE
    
    #echo_t "XCONF SCRIPT : SPIN 17 : sleeping for 30 sec, *******TEST BUILD***********"
    #sec_to_sleep=30

    sleep $sec_to_sleep
    echo_t "XCONF script : got up after $sec_to_sleep seconds"
}

# Get the MAC address of the WAN interface
getMacAddress()
{
	ifconfig  | grep $interface |  grep -v $interface:0 | tr -s ' ' | cut -d ' ' -f5
}

getBuildType()
{
   IMAGENAME=`cat /version.txt | grep "imagename:" | cut -d ":" -f 2`
   
   #Assigning default type as DEV
   type="DEV"
   echo_t "XCONF SCRIPT : Assigning default image type as: $type"

   TEMPDEV=`echo $IMAGENAME | grep DEV`
   if [ "$TEMPDEV" != "" ]
   then
       type="DEV"
   fi

   TEMPVBN=`echo $IMAGENAME | grep VBN`
   if [ "$TEMPVBN" != "" ]
   then
       type="VBN"
   fi

   TEMPPROD=`echo $IMAGENAME | grep PROD`
   if [ "$TEMPPROD" != "" ]
   then
       type="PROD"
   fi

   TEMPCQA=`echo $IMAGENAME | grep CQA`
   if [ "$TEMPCQA" != "" ]
   then
       type="GSLB"
   fi
   
   echo_t "XCONF SCRIPT : image_type returned from version.txt is $type"
   echo_t "XCONF SCRIPT : image_type returned from version.txt is $type" >> $XCONF_LOG_FILE
}

 
removeLegacyResources()
{
	#moved Xconf logging to /var/tmp/xconf.txt.0
    if [ -f /etc/Xconf.log ]; then
		rm /etc/Xconf.log
    fi

	echo_t "XCONF SCRIPT : Done Cleanup"
	echo_t "XCONF SCRIPT : Done Cleanup" >> $XCONF_LOG_FILE
}
# Check if it is still in maintenance window
checkMaintenanceWindow()
{
    start_time=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeStartTime | grep "value:" | cut -d ":" -f 3 | tr -d ' '`
    end_time=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeEndTime | grep "value:" | cut -d ":" -f 3 | tr -d ' '`

    if [ "$start_time" -eq "$end_time" ]
    then
        echo_t "XCONF SCRIPT : Start time can not be equal to end time" >> $XCONF_LOG_FILE
        echo_t "XCONF SCRIPT : Resetting values to default" >> $XCONF_LOG_FILE
        dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeStartTime string "3600"
        dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_MaintenanceWindow.FirmwareUpgradeEndTime string "14400"
        start_time=3600
        end_time=14400
    fi
    echo_t "XCONF SCRIPT : Firmware upgrade start time : $start_time" >> $XCONF_LOG_FILE
    echo_t "XCONF SCRIPT : Firmware upgrade end time : $end_time" >> $XCONF_LOG_FILE

    if [ "$UTC_ENABLE" == "true" ]
    then
        reb_hr=`LTime H`
        reb_min=`LTime M`
        reb_sec=`date +"%S"`
    else
        reb_hr=`date +"%H"`
        reb_min=`date +"%M"`
        reb_sec=`date +"%S"`
    fi

    reb_window=0
    reb_hr_in_sec=$((reb_hr*60*60))
    reb_min_in_sec=$((reb_min*60))
    reb_time_in_sec=$((reb_hr_in_sec+reb_min_in_sec+reb_sec))
    echo_t "XCONF SCRIPT : Current time in seconds : $reb_time_in_sec" >> $XCONF_LOG_FILE

    if [ $start_time -lt $end_time ] && [ $reb_time_in_sec -ge $start_time ] && [ $reb_time_in_sec -lt $end_time ]
    then
        reb_window=1
    elif [ $start_time -gt $end_time ] && [[ $reb_time_in_sec -lt $end_time || $reb_time_in_sec -ge $start_time ]]
    then
        reb_window=1
    else
        reb_window=0
    fi
}
#####################################################Main Application#####################################################

#Setting up the iptable rule that needed for ci-xconf to communicate
#This need to be removed once we have proper firewall settings

iptables -t mangle -A OUTPUT -o erouter0 -j DSCP --set-dscp-class AF32

# Determine the env type and url and write to /tmp/Xconf
#type=`printenv model | cut -d "=" -f2`

removeLegacyResources
getBuildType

echo_t "XCONF SCRIPT : IMAGE TYPE SET AS $type"

# If unit is waiting for reboot after image download,we need not have to download image again.
if [ -f $REBOOT_WAIT ]
then
    echo_t "XCONF SCRIPT : Waiting reboot after download, so exit" >> $XCONF_LOG_FILE
    exit
fi

if [ -f $DOWNLOAD_INPROGRESS ]
then
    echo_t "XCONF SCRIPT : Download is in progress, exit" >> $XCONF_LOG_FILE
    exit
fi

#Default xconf url
url="https://ci.xconfds.ccp.xcal.tv/xconf/swu/stb/"

# Override mechanism should work only for non-production build.
if [ "$type" != "PROD" ] && [ "$type" != "prod" ]; then
    if [ -f /nvram/swupdate.conf ]; then
        url=`grep -v '^[[:space:]]*#' /nvram/swupdate.conf`
        echo "XCONF SCRIPT : URL taken from /nvram/swupdate.conf override. URL=$url"
        echo "XCONF SCRIPT : URL taken from /nvram/swupdate.conf override. URL=$url"  >> $XCONF_LOG_FILE
        CDL_SERVER_OVERRIDE=1
    fi
else
    echo_t "XCONF SCRIPT : Build type is PROD. Ignoring /nvram/swupdate.conf override. URL=$url" >> $XCONF_LOG_FILE
    echo_t "XCONF SCRIPT : Build type is PROD. Ignoring /nvram/swupdate.conf override. URL=$url"
fi

echo "URL=$url" > /tmp/Xconf
echo_t "XCONF SCRIPT : Values written to /tmp/Xconf are URL=$url"
echo_t "XCONF SCRIPT : Values written to /tmp/Xconf are URL=$url" >> $XCONF_LOG_FILE

# Check if the WAN interface has an ip address, if not , wait for it to receive one
estbIp=`ifconfig $interface | grep "inet addr" | tr -s " " | cut -d ":" -f2 | cut -d " " -f1`
estbIp6=`ifconfig $interface | grep "inet6 addr" | grep "Global" | tr -s " " | cut -d ":" -f2- | cut -d "/" -f1 | tr -d " "`

echo_t "[ $(date) ] XCONF SCRIPT - Check if the WAN interface has an ip address" >> $XCONF_LOG_FILE

while [ "$estbIp" = "" ] && [ "$estbIp6" = "" ]
do
    echo_t "[ $(date) ] XCONF SCRIPT - No IP yet! sleep(5)" >> $XCONF_LOG_FILE
    sleep 5

    estbIp=`ifconfig $interface | grep "inet addr" | tr -s " " | cut -d ":" -f2 | cut -d " " -f1`
    estbIp6=`ifconfig $interface | grep "inet6 addr" | grep "Global" | tr -s " " | cut -d ":" -f2- | cut -d "/" -f1 | tr -d " "`

    echo_t "XCONF SCRIPT : Sleeping for an ipv4 or an ipv6 address on the $interface interface "
done

echo_t "XCONF SCRIPT : $interface has an ipv4 address of $estbIp or an ipv6 address of $estbIp6"

    ######################
    # QUERY & DL MANAGER #
    ######################

# Check if new image is available
echo_t "XCONF SCRIPT : Checking image availability at boot up" >> $XCONF_LOG_FILE	
if [ ! -e $NO_DOWNLOAD ]
then	
   getFirmwareUpgDetail
fi

if [ "$rebootImmediately" == "true" ];then
    echo_t "XCONF SCRIPT : Reboot Immediately : TRUE!!"
else
    echo_t "XCONF SCRIPT : Reboot Immediately : FALSE."

fi    

download_image_success=0
reboot_device_success=0
retry_download=0

while [ $download_image_success -eq 0 ]; 
do
    
   #skip download if file exist
   if [ -f $NO_DOWNLOAD ]
   then
      break
   fi

    if [ "$isPeriodicFWCheckEnabled" != "true" ]
    then
       # If an image wasn't available, check it's 
       # availability at a random time,every 24 hrs
       while  [ $image_upg_avl -eq 0 ];
       do
         echo_t "XCONF SCRIPT : Rechecking image availability within 24 hrs" 
         echo_t "XCONF SCRIPT : Rechecking image availability within 24 hrs" >> $XCONF_LOG_FILE

         # Sleep for a random time less than 
         # a 24 hour duration 
         calcRandTime 1 0
    
         # Check for the availability of an update   
         getFirmwareUpgDetail
       done
    fi

    if [ ! -f $DOWNLOAD_INPROGRESS ]
    then
        touch $DOWNLOAD_INPROGRESS
    fi

    if [ $image_upg_avl -eq 1 ];then

        #Wait for dnsmasq to start
#DNSMASQ_PID=`pidof dnsmasq`
#
#       while [ "$DNSMASQ_PID" = "" ]
#       do
#           sleep 10
#           echo_t "XCONF SCRIPT : Waiting for dnsmasq process to start"
#           echo_t "XCONF SCRIPT : Waiting for dnsmasq process to start" >> $XCONF_LOG_FILE
#           DNSMASQ_PID=`pidof dnsmasq`
#       done
#
#       echo_t "XCONF SCRIPT : dnsmasq process  started!!"
#       echo_t "XCONF SCRIPT : dnsmasq process  started!!" >> $XCONF_LOG_FILE
    
        # Whitelist the returned firmware location
        #echo_t "XCONF SCRIPT : Whitelisting download location : $firmwareLocation"
        #echo_t "XCONF SCRIPT : Whitelisting download location : $firmwareLocation" >> $XCONF_LOG_FILE
        echo "$firmwareLocation" > /tmp/xconfdownloadurl
        #/etc/whitelist.sh "$firmwareLocation"

        # Set the url and filename
        echo "XCONF SCRIPT : URL --- $firmwareLocation and NAME --- $firmwareFilename"
        echo "XCONF SCRIPT : URL --- $firmwareLocation and NAME --- $firmwareFilename" >> $XCONF_LOG_FILE
        XconfHttpDl set_http_url $firmwareLocation $firmwareFilename >> $XCONF_LOG_FILE
        set_url_stat=$?
        
        # If the URL was correctly set, initiate the download
        if [ $set_url_stat -eq 0 ];then
        
            # An upgrade is available and the URL has ben set 
            # Wait to download in the maintenance window if the RebootImmediately is FALSE
            # else download the image immediately

            if [ "$rebootImmediately" == "false" ];then

				echo_t "XCONF SCRIPT : Reboot Immediately : FALSE. Downloading image now"
				echo_t "XCONF SCRIPT : Reboot Immediately : FALSE. Downloading image now" >> $XCONF_LOG_FILE
            else
                echo_t  "XCONF SCRIPT : Reboot Immediately : TRUE : Downloading image now"
                echo_t  "XCONF SCRIPT : Reboot Immediately : TRUE : Downloading image now" >> $XCONF_LOG_FILE
            fi
			
			#echo_t "XCONF SCRIPT : Sleep to prevent gw refresh error"
			#echo_t "XCONF SCRIPT : Sleep to prevent gw refresh error" >> $XCONF_LOG_FILE
            #sleep 60

	        # Start the image download
		echo "[ $(date) ] XCONF SCRIPT  ### httpdownload started ###" >> $XCONF_LOG_FILE
	        XconfHttpDl http_download >> $XCONF_LOG_FILE
	        http_dl_stat=$?
		echo -e "\n"
		echo_t "[ $(date) ] XCONF SCRIPT  ### httpdownload completed ###" >> $XCONF_LOG_FILE
	        echo_t "XCONF SCRIPT : HTTP DL STATUS $http_dl_stat"
	        echo_t "**XCONF SCRIPT : HTTP DL STATUS $http_dl_stat**" >> $XCONF_LOG_FILE
			
	        # If the http_dl_stat is 0, the download was succesful,          
            # Indicate a succesful download and continue to the reboot manager
		
            if [ $http_dl_stat -eq 0 ];then
                echo_t "XCONF SCRIPT : HTTP download Successful" >> $XCONF_LOG_FILE
                # Indicate succesful download
                download_image_success=1
                rm -rf $DOWNLOAD_INPROGRESS
            else
                # Indicate an unsuccesful download
                echo_t "XCONF SCRIPT : HTTP download NOT Successful" >> $XCONF_LOG_FILE
                rm -rf $DOWNLOAD_INPROGRESS
                download_image_success=0
                # Set the flag to 0 to force a requery
                image_upg_avl=0
                if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
			# No need of looping here as we will trigger a cron job at random time
			exit
		fi
            fi

        else
            echo_t "XCONF SCRIPT : ERROR : URL & Filename not set correctly.Requerying "
            echo_t "XCONF SCRIPT : ERROR : URL & Filename not set correctly.Requerying " >> $XCONF_LOG_FILE
	     download_image_success=0
             # Set the flag to 0 to force a requery
             image_upg_avl=0
             rm -rf $DOWNLOAD_INPROGRESS
 	      if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
          	   retry_download=`expr $retry_download + 1`
		       
        	   if [ $retry_download -eq 3 ]
          	   then
             	       echo_t "XCONF SCRIPT : ERROR : URL & Filename not set correctly after 3 retries.Exiting" >> $XCONF_LOG_FILE
        	       exit  
          	   fi
              fi
        fi
    fi
done

    ##################
    # REBOOT MANAGER #
    ##################

    # Try rebooting the device if :
    # 1. Issue an immediate reboot if still within the maintenance window and phone is on hook
    # 2. If an immediate reboot is not possile ,calculate and remain within the reboot maintenance window
    # 3. The reboot ready status is OK within the maintenance window 
    # 4. The rebootImmediate flag is set to true

while [ $reboot_device_success -eq 0 ]; do
                    
    # Verify reboot criteria ONLY if rebootImmediately is FALSE
    if [ "$rebootImmediately" == "false" ];then

        # Check if still within reboot window
        checkMaintenanceWindow

        if [ $reb_window -eq 1 ]; then
            echo_t "XCONF SCRIPT : Still within current maintenance window for reboot"
            echo_t "XCONF SCRIPT : Still within current maintenance window for reboot" >> $XCONF_LOG_FILE
            reboot_now=1
        else
            echo_t "XCONF SCRIPT : Not within current maintenance window for reboot.Rebooting in the next window"
            echo_t "XCONF SCRIPT : Not within current maintenance window for reboot.Rebooting in the next window" >> $XCONF_LOG_FILE
            reboot_now=0
        fi

        # If we are not supposed to reboot now, calculate random time
        # to reboot in next maintenance window 
        if [ $reboot_now -eq 0 ];then
            calcRandTime 0 1 r
        fi    

        # Check the Reboot status
        # Continously check reboot status every 10 seconds  
        # till the end of the maintenace window until the reboot status is OK
        XconfHttpDl http_reboot_status >> $XCONF_LOG_FILE
        http_reboot_ready_stat=$?

        while [ $http_reboot_ready_stat -eq 1 ]   
        do     
            sleep 10
            checkMaintenanceWindow

            if [ $reb_window -eq 1 ]
            then
                #We're still within the reboot window 
                XconfHttpDl http_reboot_status >> $XCONF_LOG_FILE
                http_reboot_ready_stat=$?
                    
            else
                #If we're out of the reboot window, exit while loop
                break
            fi
        done 

    else
        #RebootImmediately is TRUE
        echo_t "XCONF SCRIPT : Reboot Immediately : TRUE!, rebooting device now"
        http_reboot_ready_stat=0    
        echo_t "XCONF SCRIPT : http_reboot_ready_stat is $http_reboot_ready_stat"
                            
    fi 
                    
    echo_t "XCONF SCRIPT : http_reboot_ready_stat is $http_reboot_ready_stat" >> $XCONF_LOG_FILE

    # The reboot ready status changed to OK within the maintenance window,proceed
    if [ $http_reboot_ready_stat -eq 0 ];then
     
 	if [ $abortReboot_count -lt 5 ];then
		#Wait for Notification to propogate
		deferfw=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.RPC.DeferFWDownloadReboot | grep value | cut -d ":" -f 3 | tr -d ' ' `
		echo_t "XCONF SCRIPT : Sleeping for $deferfw seconds before reboot" >> $XCONF_LOG_FILE
		touch $deferReboot 
		dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.RPC.RebootPendingNotification uint $deferfw
		sleep $deferfw
	else
		echo_t "XCONF SCRIPT : Abort Count reached maximum limit $abortReboot_count" >> $XCONF_LOG_FILE
	fi

     #Abort Reboot
      if [ ! -e "$ABORT_REBOOT" ]
      then
        #Reboot the device
	echo_t "XCONF SCRIPT : Reboot possible. Issuing reboot command"
	echo_t "RDKB_REBOOT : Reboot command issued from XCONF"
	XconfHttpDl http_reboot >> $XCONF_LOG_FILE 
	reboot_device=$?
		       
        # This indicates we're within the maintenace window/rebootImmediate=TRUE
        # and the reboot ready status is OK, issue the reboot
        # command and check if it returned correctly
		if [ $reboot_device -eq 0 ];then
            reboot_device_success=1
            #For rdkb-4260
            echo_t "Creating file /nvram/reboot_due_to_sw_upgrade"
            touch /nvram/reboot_due_to_sw_upgrade
            echo_t "XCONF SCRIPT : REBOOTING DEVICE"
            echo_t "RDKB_REBOOT : Rebooting device due to software upgrade"
            echo_t "XCONF SCRIPT : setting LastRebootReason"
            dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_LastRebootReason string Software_upgrade
	    echo_t "XCONF SCRIPT : SET succeeded"

                
        else 
            # The reboot command failed, retry in the next maintenance window 
            reboot_device_success=0
            #Goto start of Reboot Manager again  
	 fi
      else
                echo_t "XCONF SCRIPT : Reboot aborted by user, will try in next maintenance window " >> $XCONF_LOG_FILE
		abortReboot_count=$((abortReboot_count+1))
		echo_t "XCONF SCRIPT : Abort Count is  $abortReboot_count" >> $XCONF_LOG_FILE
                touch $NO_DOWNLOAD
                rm -rf $ABORT_REBOOT
                rm -rf $deferReboot
                reboot_device_success=0
                if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
                      exit
                fi
      fi

     # The reboot ready status didn't change to OK within the maintenance window 
     else
        reboot_device_success=0
	echo_t " XCONF SCRIPT : Device is not ready to reboot : Retrying in next reboot window ";
        # Goto start of Reboot Manager again  
     fi
                    
done # While loop for reboot manager
