#!/bin/sh

######## Set Initial Variables ###################

	USER=`who | grep "console" | cut -d" " -f1`

	CurrentUSER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /Loginwindow/ { print $3 }' )

	MacName=$( scutil --get ComputerName)
	echo $CurrentUSER
	uid=$(id -u "$CurrentUSER") 
    Libcopied=0
############## End of Set Initial Variables #############

###################### Set Log file ##################

	if [ -f "/private/tmp/LibrarySync.log" ]; then 
 		mv  "/private/tmp/LibrarySync.log" "/private/tmp/LibrarySynclog-`date`.log"
	fi
 	sleep 1
    touch /private/tmp/LibrarySync.log 
    chmod 777 /private/tmp/LibrarySync.log
    chmod 777 /usr/local/ConsoleUserWarden/bin/ConsoleUserWarden-UserLoggedOut
    
 ###################### End of Set Log file ##################
			
            ###### START OF FUNCTIONS #######

############## Run as Console User Function ##############
runAsUser() {  
  if [ "$CurrentUSER" != "loginwindow" ]; then
    launchctl asuser "$uid" sudo -u "$CurrentUSER" "$@"
  else
    echo "no user logged in"
    # uncomment the exit command
    # to make the function exit with an error when no user is logged in
    #exit 1
  fi
}
############## End of Console User Function ##############


################ Check if AD Account Function ##################
CheckIfADAccount()  {
	loggedInUser=$(stat -f%Su /dev/console)

	accountCheck=$(dscl . read /Users/$loggedInUser OriginalAuthenticationAuthority 2>/dev/null)

	if [ "$accountCheck" != "" ]; then
	     echo "User $loggedInUser is an AD account"
	     AD=1
	else
	     echo "User $loggedInUser is a local account"
	     AD=0
	fi
}
################ END Check if AD Account #####################


################ Check type of AD Account Function ##################
CheckADUserType()  {

accountCheck=$(dscl . read /Users/$CurrentUSER OriginalAuthenticationAuthority 2>/dev/null)
echo "checking AD"
if [ "$accountCheck" != "" ] && [[ $CurrentUSER = [0-9]* ]]; then
     echo "`date` - User $CurrentUSER is a student account" >> /tmp/LibrarySync.log
     echo "`date` - User $CurrentUSER is a student account"
        ADUser='Student'
			   
	 
else
     echo "`date` - User $CurrentUSER is a staff AD account"  >> /tmp/LibrarySync.log
      echo "`date` - User $CurrentUSER is a staff AD account"
    ADUser='Staff'
            
fi
}
################ END Check if student AD Account #####################


############## Check Student Home Folder Path Structure Function ##########
CheckStudentFolderPath()	{

	if [ -d /Volumes/$CurrentUSER ]; then
    	MYHOMEDIR=/Volumes/$CurrentUSER
    fi
		
    if [ -d /Volumes/StudentHome\$ ]; then 
 		MYHOMEDIR=/Volumes/StudentHome\$/$CurrentUSER
	else
	    MYHOMEDIR=/Volumes/Studenthome\$/$CurrentUSER
	fi
}
############## End of Student Home Folder check Function ##############

############## Check Staff Home Folder Path Structure Function ##########
CheckStaffFolderPath()	{

	if [ -d /Volumes/$CurrentUSER ]; then
    	MYHOMEDIR=/Volumes/$CurrentUSER
    fi
		
    if [ -d /Volumes/StaffHome\$ ]; then 
 		MYHOMEDIR=/Volumes/StaffHome\$/$CurrentUSER
	else
	    MYHOMEDIR=/Volumes/Staffhome\$/$CurrentUSER
	fi
}
############## End of Staff Home Folder check Function ##############


################ Redirect AD Account Function ##################
RedirectIfADAccount()  {

  	now=$( date +%T )
    echo "Start RedirectIfADAccount function - $now" >> /tmp/LibrarySync.log 
	echo "Start RedirectIfADAccount function - $now"

	# Redirect home folders to server
	if [ ! -f /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.RedirectedFolders.plist ]; then
		
		echo "Redirecting folders to $MYHOMEDIR for $CurrentUSER" >> /tmp/LibrarySync.log 
		echo "Redirecting folders to $MYHOMEDIR for $CurrentUSER"
      
		mounted=1
		folders=("Pictures" "Documents" "Downloads" "Desktop")

		echo "starting redirects"

		while [ $mounted -gt 0 ]; do

 
			if [ -d "$MYHOMEDIR" ]; then
		    	 echo "`date` - $MYHOMEDIR exists"
                
             for i in "${folders[@]}"; do

	 	       	if [ -d "$MYHOMEDIR/$i" ]; then
 	          		 echo "$i available"
 		       	else
 		         	 echo "$i not available, creating...."
 		         	 mkdir "$MYHOMEDIR/$i"
   			   	 fi

		        echo "testing symlinks"

		        if [ ! -L /Users/$CurrentUSER/$i ]; then
 		            echo "$i folder not linked, now linking"
		            chmod -R 777 /Users/$CurrentUSER/$I
				    rm -R /Users/$CurrentUSER/$i
  	   		        ln -s "$MYHOMEDIR/$i" /Users/$CurrentUSER/
      			else
               		echo "$i already linked, going away now"
       			fi

   			 done

    		mounted=`expr $mounted - 1`
			else
    			echo "$MYHOMEDIR not available, waiting..."
    			echo "sleeping"
				sleep 5
			fi
		done

        
	touch /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.RedirectedFolders.plist
	chown $CurrentUSER /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.RedirectedFolders.plist
	chmod 755 /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.RedirectedFolders.plist
fi

  	now=$( date +%T )
    echo "Finish RedirectIfADAccount function - $now" >> /tmp/LibrarySync.log 
	echo "Finish RedirectIfADAccount function - $now"

}        
############### End of Redirect Function #################


############### Pin Redirected Folders Function ##########
PinRedirectedFolders()	{

	uid=$(id -u "$CurrentUSER")

	launchctl asuser $uid /usr/local/bin/mysides remove "Downloads"

	launchctl asuser $uid /usr/local/bin/mysides remove "Documents"
           
	launchctl asuser $uid /usr/local/bin/mysides remove "Pictures"

	launchctl asuser $uid /usr/local/bin/mysides remove "Music"

	launchctl asuser $uid /usr/local/bin/mysides remove "Desktop"

#	launchctl asuser $uid /usr/local/bin/mysides remove "Videos"

	launchctl asuser $uid /usr/local/bin/mysides remove "Library"


# Pin the Home folders to the Finder Sidebar

	launchctl asuser $uid /usr/local/bin/mysides add "Desktop" file:///Users/$CurrentUSER/Desktop

	launchctl asuser $uid /usr/local/bin/mysides add "Documents" file:///Users/$CurrentUSER/Documents

	launchctl asuser $uid /usr/local/bin/mysides add "Downloads" file:///Users/$CurrentUSER/Downloads
           
	launchctl asuser $uid /usr/local/bin/mysides add "Library" file:///Users/$CurrentUSER/Library

	launchctl asuser $uid /usr/local/bin/mysides add "Music" file:///Users/$CurrentUSER/Music

	launchctl asuser $uid /usr/local/bin/mysides add "Movies" file:///Users/$CurrentUSER/Movies
    
    launchctl asuser $uid /usr/local/bin/mysides add "Pictures" file:///Users/$CurrentUSER/Pictures

	touch /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.PinFolders.plist
    chown $CurrentUSER /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.PinFolders.plist
    chmod 755 $CurrentUSER /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.PinFolders.plist

}
################ End of Folder Pinning Function ####################


############### Library Template Function #################
CreateHomeLibraryFolders()  {

  	now=$( date +%T )
    echo "Start CreateHomeLibraryFolder function - $now" >> /tmp/LibrarySync.log 
	echo "Start CreateHomeLibraryFolder function - $now"



     	if [ -d "$MYHOMEDIR/Library/SyncedPreferences" ]; then
            echo "Library available"
            touch "$MYHOMEDIR/Library/Preferences/com.gvsd.HomeLibraryExists.plist" 
            touch "/Users/$CurrentUSER/Library/Preferences/com.gvsd.HomeLibraryExists.plist" 
            Libcopied=1

        else
       			chmod -R 777 $MYHOMEDIR
       
  			    if [ ! -d "$MYHOMEDIR/Library" ]; then
            	mkdir "$MYHOMEDIR/Library"
                chown $CurrentUSER "$MYHOMEDIR/Library"
                fi       
 
      			if [ ! -d "$MYHOMEDIR/Library/Preferences" ]; then
    	        	mkdir "$MYHOMEDIR/Library/Preferences"
    	            chown $CurrentUSER "$MYHOMEDIR/Library/Preferences"
     	           chmod -R 777 "$MYHOMEDIR/Library/Preferences"
   				fi 
     
     			if [ ! -d "$MYHOMEDIR/Library/PreferencePanes" ]; then
        	    	mkdir "$MYHOMEDIR/Library/PreferencePanes"
        	        chown $CurrentUSER "$MYHOMEDIR/Library/PreferencePanes"
         	       chmod -R 777 "$MYHOMEDIR/Library/PreferencePanes"
   				fi        
          
     			if [ ! -d $MYHOMEDIR/Library/Safari ]; then
     	       		mkdir $MYHOMEDIR/Library/Safari
               		chown $CurrentUSER $MYHOMEDIR/Library/Safari
                	chmod -R 777 $MYHOMEDIR/Library/Safari
     			fi        
     
     			if [ ! -d $MYHOMEDIR/Library/Saved\ Application\ State ]; then
            		mkdir $MYHOMEDIR/Library/Saved\ Application\ State
                	chown $CurrentUSER $MYHOMEDIR/Library/Saved\ Application\ State
                	chmod -R 777 $MYHOMEDIR/Library/Saved\ Application\ State
     			fi        
     			if [ ! -d $MYHOMEDIR/Library/SyncedPreferences ]; then
            		mkdir $MYHOMEDIR/Library/SyncedPreferences
                	chown $CurrentUSER $MYHOMEDIR/Library/SyncedPreferences
                	chmod -R 777 $MYHOMEDIR/Library/SyncedPreferences
     			fi               
       			touch "$MYHOMEDIR/Library/Preferences/com.gvsd.HomeLibraryExists.plist" 
       			touch "/Users/$CurrentUSER/Library/Preferences/com.gvsd.HomeLibraryExists.plist" 
 	   fi 
       
    now=$( date +%T )
    echo "Finish CreateHomeLibraryFolder function - $now" >> /tmp/LibrarySync.log 
	echo "Finish CreateHomeLibraryFolder function - $now"    
}
############### End Library Template Function #################


################ Create Library folders in Documents Function ####################

CreateDocumentlibraryfolders() { 

  	now=$( date +%T )
    echo "Start CreateDocumentlibraryfolders function - $now" >> /tmp/LibrarySync.log 
	echo "Start CreateDocumentlibraryfolders function - $now"


# Create Application Support Folders in Documents

         if [ ! -d /Users/$CurrentUSER/Documents/Application\ Support ]; then
             mkdir /Users/$CurrentUSER/Documents/Application\ Support
         fi


	     if [ ! -d "/Users/$CurrentUSER/Documents/Application Support/minecraft" ]; then
             mkdir /Users/$CurrentUSER/Documents/Application\ Support/minecraft
         fi
            
        
         if [ ! -d "/Users/$CurrentUSER/Documents/Application Support/minecraft/saves" ]; then
           	 mkdir /Users/$CurrentUSER/Documents/Application\ Support/minecraft/saves
             chown -R $CurrentUSER /Users/$CurrentUSER/Documents/Application\ Support/minecraft
             chmod -R 777 /Users/$CurrentUSER/Documents/Application\ Support/minecraft/saves
         fi
         
     
         if [ ! -d /Users/$CurrentUSER/Documents/GarageBand ]; then 
     		mkdir /Users/$CurrentUSER/Documents/GarageBand
       		chown -R $CurrentUSER /Users/$CurrentUSER/Documents/GarageBand
   		 fi


         if [ ! -d /Users/$CurrentUSER/Documents/Sync ]; then
             mkdir /Users/$CurrentUSER/Documents/Sync
             chown -R $CurrentUSER /Users/$CurrentUSER/Documents/Sync
             chmod -R 777 /Users/$CurrentUSER/Documents/Sync
         fi    
 
 
         if [ ! -d /Users/$CurrentUSER/Documents/Sync/Twine ]; then
             mkdir /Users/$CurrentUSER/Documents/Sync/Twine
             chown -R $CurrentUSER /Users/$CurrentUSER/Documents/Sync/Twine
             chmod -R 777 /Users/$CurrentUSER/Documents/Sync/Twine
         fi    

         if [ ! -d /Users/$CurrentUSER/Documents/Sync/Twine/Stories ]; then
             mkdir /Users/$CurrentUSER/Documents/Sync/Twine/Stories
             chown -R $CurrentUSER /Users/$CurrentUSER/Documents/Sync/Twine/Stories
             chmod -R 777 /Users/$CurrentUSER/Documents/Sync/Twine/Stories
         fi    

         if [ ! -d /Users/$CurrentUSER/Documents/Sync/Twine/Backups ]; then
             mkdir /Users/$CurrentUSER/Documents/Sync/Twine/Backups
             chown -R $CurrentUSER /Users/$CurrentUSER/Documents/Sync/Twine/Backups
             chmod -R 777 /Users/$CurrentUSER/Documents/Sync/Twine/Backups
         fi    



         if [ ! -d /Users/$CurrentUSER/Twine ]; then
             mkdir /Users/$CurrentUSER/Twine
             chown -R $CurrentUSER /Users/$CurrentUSER/Twine
             chmod -R 777 /Users/$CurrentUSER/Twine
         fi    
         
# The following is for use with the Chrome launcher that defines a user profile folder
        
         if [ ! -d /Users/$CurrentUSER/Documents/Application\ Support/Google/Chrome/Profile\ 1 ]; then
 	         mkdir /Users/$CurrentUSER/Documents/Application\ Support/Google/Chrome/Profile\ 1
             chown -R $CurrentUSER /Users/$CurrentUSER/Documents/Application\ Support
   		fi 
        
    now=$( date +%T )
    echo "Finish CreateDocumentlibraryfolders function - $now" >> /tmp/LibrarySync.log 
	echo "Finish CreateDocumentlibraryfolders function - $now"
    
       
 }
       
################ End of Create Library folders in Documents ####################  		 

 
################ Prestage App folders Function ####################

PreStageUnlinkedAppFolders() {  

  	now=$( date +%T )
    echo "Start PreStageUnlinkedAppFolders function - $now" >> /tmp/LibrarySync.log 
	echo "Start PreStageUnlinkedAppFolders function - $now"

# Create Application Support Folders in Library and in Music

         if [ ! -d /Users/$CurrentUSER/Library/Application\ Support ]; then
             mkdir /Users/$CurrentUSER/Library/Application\ Support
         fi
  
	     if [ ! -d /Users/$CurrentUSER/Library/Application\ Support/minecraft ]; then
             mkdir /Users/$CurrentUSER/Library/Application\ Support/minecraft
         fi
       
        if [ ! -d /Users/$CurrentUSER/Library/Application\ Support/minecraft/saves ]; then
           	 mkdir /Users/$CurrentUSER/Library/Application\ Support/minecraft/saves
            #chown -R $CurrentUSER /Users/$CurrentUSER/Documents/Application\ Support/minecraft/saves
            chmod -R 777 /Users/$CurrentUSER/Documents/Application\ Support/minecraft/saves
            chmod -R 777 /Users/$CurrentUSER/Documents/Application\ Support/minecraft/saves
         fi
         
         if [ ! -d /Users/$CurrentUSER/Music/Audio\ Music\ Apps ]; then 
     		mkdir /Users/$CurrentUSER/Music/Audio\ Music\ Apps
            chown -R $CurrentUSER /Users/$CurrentUSER/Documents/Audio\ Music\ Apps
       		chmod -R 777 /Users/$CurrentUSER/Documents/Audio\ Music\ Apps
   		 fi
         
         if [ ! -d /Users/$CurrentUSER/Music/GarageBand ]; then 
     		mkdir /Users/$CurrentUSER/Music/GarageBand
            chown -R $CurrentUSER /Users/$CurrentUSER/Music/GarageBand
       		chmod -R 777 /Users/$CurrentUSER/Music/GarageBand
   		 fi

         if [ ! -d /Users/$CurrentUSER/Library/Application\ Support/Google ]; then
             mkdir /Users/$CurrentUSER/Library/Application\ Support/Google
         fi
            
         if [ ! -d /Users/$CurrentUSER/Library/Application\ Support/Google/Chrome ]; then
             mkdir /Users/$CurrentUSER/Library/Application\ Support/Google/Chrome
         fi
            
         if [ ! -d /Users/$CurrentUSER/Library/Application\ Support/Google/Chrome/Profile\ 1 ]; then
 	         mkdir /Users/$CurrentUSER/Library/Application\ Support/Google/Chrome/Profile\ 1
             chown -R $CurrentUSER /Users/$CurrentUSER/Library/Application\ Support/Google
 			 chmod -R 777 /Users/$CurrentUSER/Library/Application\ Support/Google
   		 fi
    
    now=$( date +%T )
    echo "Finish PreStageUnlinkedAppFolders function - $now" >> /tmp/LibrarySync.log 
	echo "Finishe PreStageUnlinkedAppFolders function - $now"
   
 }
       
 ################ End of Prestage App Folders ####################  		 


 ################ link Library folders function ####################       
         
linklibraryfolders() {  

  	now=$( date +%T )
    echo "Start linklibraryfolders function - $now" >> /tmp/LibrarySync.log 
	echo "Start linklibraryfolders function - $now"
    
    # Symlink minecraft folders to machine local shared
    
        if [ ! -d /Users/Shared/minecraft ]; then
    		mkdir /Users/Shared/minecraft
        fi
        if [ ! -d /Users/$CurrentUSER/Library/Application\ Support/minecraft ]; then
    		mkdir /Users/$CurrentUSER/Library/Application\ Support/minecraft
        fi    
    
    minefolders=(
    "assets" 
    "versions"
    )
    
    for (( m=0; m < ${#minefolders[@]}; m++ )); do
  	         
         if [ -d "/Users/Shared/minecraft/${minefolders[m]}" ]; then
 	           echo "Shared minecraft ${minefolders[m]} folder available"
                chown -R root:wheel /Users/Shared/minecraft/${minefolders[m]}
                chmod -R 777 /Users/Shared/minecraft/${minefolders[m]}
 		 else
 		       echo "Shared minecraft ${minefolders[m]} not available, creating...."
 		       mkdir /Users/Shared/minecraft/${minefolders[m]}
               chown -R root:wheel /Users/Shared/minecraft/${minefolders[m]}
               chmod -R 777 /Users/Shared/minecraft/${minefolders[m]}
   		 fi
    	    
         if [ ! -L "/Users/$CurrentUSER/Library/Application Support/minecraft/${minefolders[m]}" ]; then
             echo "Application Support subfolder minecraft ${minefolders[m]} is not linked, now linking"
             rm -R "/Users/$CurrentUSER/Library/Application Support/minecraft/${minefolders[m]}"
            ln -s "/Users/Shared/minecraft/${minefolders[m]}" "/Users/$CurrentUSER/Library/Application Support/minecraft/"
         else
              echo "minecraft ${minefolders[m]} subfolder already linked, going away now"
         fi
	done

# Symlink Application Sub Folders

        echo "creating Application Support subfolder symlinks"

        AppSubfolders=(
		"Dock"
        "iMovie"
        )

		echo "starting symlinks"

        for x in "${AppSubfolders[@]}"; do

            
            if [ -d /Users/$CurrentUSER/Documents/Application\ Support/$x ]; then
 	           echo "$x available"
 		    else
 		       echo "$x not available, creating...."
 		       mkdir /Users/$CurrentUSER/Documents/Application\ Support/$x
               chmod -R 777 /Users/$CurrentUSER/Documents/Application\ Support/$x
   		    fi

#			  ap=${AppSubfolders[x]//[[:blank:]]} 
#             echo "$ap"
#            aplistlink="com.gvsd.${ap}.Linked.plist"
#            echo "$aplistlink"

		    echo "testing symlinks"
            iold="${x}_OLD"    

     	    if [ ! -L /Users/$CurrentUSER/Library/Application\ Support/$x ]; then
               echo "Application Support subfolder $x is not linked, now linking"
       		   rm -Rf /Users/$CurrentUSER/Library/Application\ Support/$x
  	   		   ln -s /Users/$CurrentUSER/Documents/Application\ Support/$x /Users/$CurrentUSER/Library/Application\ Support/
            else
               echo "$x subfolder already linked, going away now"
            fi

   	    done 
        
    now=$( date +%T )
    echo "Finish linklibraryfolders function - $now" >> /tmp/LibrarySync.log 
	echo "Finish linklibraryfolders function - $now"
}
################ End of Link library function #####################

################ Link Twine Folders function #####################

linktwinefolders() { 

	 now=$( date +%T )
    echo "Start linktwinefolders Function - $now" >> /tmp/LibrarySync.log 
	echo "Start linktwinefolders Function - $now"

            
            if [ -d /Users/$CurrentUSER/Twine ]; then
 	           echo "Twine folder available"
 		    else
 		       echo "Twine is not available, creating...."
 		       mkdir /Users/$CurrentUSER/Twine
               chmod -R 777 /Users/$CurrentUSER/Twine
   		    fi


     	    if [ ! -L /Users/$CurrentUSER/Documents/Twine ]; then
               echo "Twine is not linked, now linking"
       		   rm -Rf /Users/$CurrentUSER/Documents/Twine
  	   		   ln -s /Users/$CurrentUSER/Twine /Users/$CurrentUSER/Documents/
            else
               echo "Twine subfolder already linked, going away now"
            fi
	 now=$( date +%T )
    echo "Finished linktwinefolders Function - $now" >> /tmp/LibrarySync.log 
	echo "Finished linktwinefolders Function - $now"


}
################ End of Link Twine folders function #####################

################ Fix Library Perms function #####################

fixLibraryPerms() {

  	now=$( date +%T )
    echo "Start fixLibraryPerms function - $now" >> /tmp/LibrarySync.log 
	echo "Start fixLibraryPerms function - $now"

	if [ ! "$(stat -f '%A' /Applications/Minecraft.app/Contents/MacOS/launcher)" = 777 ]; then
		chown -R root:wheel /Applications/Minecraft.app 
		chmod -R 777 /Applications/Minecraft.app/Contents/MacOS/launcher
		now=$( date +%T )
		echo "$now - Set permissions for Minecraft" >> /tmp/LibrarySync.log 
		fi

	if [ ! "$(stat -f '%A' /Users/$CurrentUSER/Library/Application\ Support/minecraft)" = 777 ]; then
		chmod -R 777 /Users/$CurrentUSER/Library/Application\ Support/minecraft
		chmod -R 777 /Users/$CurrentUSER/Documents/Application\ Support/minecraft
 		chown -R $CurrentUSER  /Users/$CurrentUSER/Documents/Application\ Support/minecraft/saves           
 		chown -R root:wheel /Users/Shared/minecraft/assets
 		chmod -R 777 /Users/Shared/minecraft/assets
    fi

	if [ ! "$(stat -f '%a' chmod -R 777 /Users/$CurrentUSER/Music/Audio\ Music\ Apps)" == "777" ]; then
 		chmod -R 777 /Users/$CurrentUSER/Music/Audio\ Music\ Apps
 	fi
 
 	if [ ! "$(stat -f '%A' /Users/$CurrentUSER/Music/GarageBand)" = 777 ]; then
 		chmod -R 777 /Users/$CurrentUSER/Music/GarageBand
        echo "$now - Set permissions for Music Folder" >> /tmp/LibrarySync.log 
    fi
 
	if [ ! "$(stat -f '%A' /Users/$CurrentUSER/Library/Application\ Support/Google)" = "777" ]; then
 		chmod -R 777 /Users/$CurrentUSER/Library/Application\ Support/Google
    fi 
 
 	now=$( date +%T )
    echo "Finished fixLibraryPerms function - $now" >> /tmp/LibrarySync.log 
	echo "Finished fixLibraryPerms function - $now"

}
################ End of Library Perms function #####################


################ Copy Roaming App Files function #####################

CopyRoamingAppFiles() {
   	now=$( date +%T )
    echo "Start copy of roaming App file at $now" >> /tmp/LibrarySync.log 
	echo "Start copy of roaming App file at $now"

### Minecraft Files

 	if [ ! -d /Users/$CurrentUSER/Library/Application\ Support/minecraft/launcher ]; then
	rm -R /Users/$CurrentUSER/Library/Application\ Support/minecraft/launcher
 	fi

 # if [ -f /Users/Shared/minecraft/launcher/launcher.bundle ]; then
 # 	  rsync -rua /Users/Shared/minecraft/launcher/ /Users/$CurrentUSER/Library/Application\ Support/minecraft/launcher/ 
 # fi
    
 rsync -rua /Users/$CurrentUSER/Documents/Application\ Support/minecraft/saves/ /Users/$CurrentUSER/Library/Application\ Support/minecraft/saves/ 
 cp -Rf /Users/$CurrentUSER/Documents/Application\ Support/minecraft/launcher_accounts.json  /Users/$CurrentUSER/Library/Application\ Support/minecraft 
 cp -Rf /Users/$CurrentUSER/Documents/Application\ Support/minecraft/launcher_msa_credentials.bin  /Users/$CurrentUSER/Library/Application\ Support/minecraft  
 cp -Rf /Users/$CurrentUSER/Documents/Application\ Support/minecraft/options.txt  /Users/$CurrentUSER/Library/Application\ Support/minecraft 
 chmod -R 777 /Users/Shared/minecraft
  
 now=$( date +%T )
 echo "$now - Copied Minecraft" >> /tmp/LibrarySync.log
 echo "$now - Copied Minecraft"

### Garageband Files

 rsync -rua /Users/$CurrentUSER/Documents/GarageBand/ /Users/$CurrentUSER/Music/GarageBand/
 echo "$now - Copied GarageBand Folder" >> /tmp/LibrarySync.log 
 echo "$now - Copied GarageBand Folder"

### Twine Files

 rsync -rua /Users/$CurrentUSER/Documents/Sync/Twine/ /Users/$CurrentUSER/Twine/
 echo "$now - Copied Twine Folders" >> /tmp/LibrarySync.log 
 echo "$now - Copied Twine Folders"   
  
  
}
################ End of Roaming App files function #####################


############### Do something at exit Function ####################

OnExit() {
   jamf policy -event synctohome
	}
####################### End of  exit Function ####################

	
####################### Sync Home Library to Local Function ###########

SyncHomeLibraryToLocal() {

	 now=$( date +%T )
    echo "Start SyncHomeLibraryToLocal Function - $now" >> /tmp/LibrarySync.log 
	echo "Start SyncHomeLibraryToLocal Function - $now"

    if [ -f "$MYHOMEDIR/Library/Preferences/com.gvsd.HomeLibraryExists.plist" ]; then
		echo "`date` - Start sync from home for $CurrentUSER" >> /tmp/LibrarySync.log
		echo "`date` - Start sync from home for $CurrentUSER" 
        # runAsUser osascript -e 'display alert "Sync From Home" message "Your Library is downloading."' &
        now=$( date +%T )
	   rm -f "$MYHOMEDIR/Library/Preferences/com.apple.dock.plist" 
    
		libfolders=(
  	    "Preferences"
	    "PreferencePanes"
	    "Saved Application State"
	    "Safari"
	    "SyncedPreferences"
        )
      
    	for (( n=0; n < ${#libfolders[@]}; n++ )); do
  	      now=$( date +%T )
          chown -R $CurrentUSER "/Users/$CurrentUSER/Library/${libfolders[n]}"
          chmod -R 777 "/Users/$CurrentUSER/Library/${libfolders[n]}"
#         chmod -R 777 "$MYHOMEDIR/Library/${libfolders[n]}"
	      rsync -rua --exclude=".*" "$MYHOMEDIR/Library/${libfolders[n]}/" "/Users/$USER/Library/${libfolders[n]}/"
 	      echo "$now - rsync code for ${libfolders[n]} from home is $?" >> /tmp/LibrarySync.log 
          echo "$now - rsync code for ${libfolders[n]} from home is $?"
        done
        touch "$MYHOMEDIR/Library/Preferences/com.gvsd.HomeLibraryExists.plist" 
        touch "/Users/$CurrentUSER/Library/Preferences/com.gvsd.HomeLibraryExists.plist"        
    fi
    
    	 now=$( date +%T )
    echo "Finished SyncHomeLibraryToLocal Function - $now" >> /tmp/LibrarySync.log 
	echo "Finished SyncHomeLibraryToLocal Function - $now"
}

##################### End of Sync Home Library to Local Function ###########



						#####END OF FUNCTIONS#####

######################## START THE SCRIPT COMMANDS #########################

touch /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.LogonScriptRun.plist
chown $CurrentUser /Users/$CurrentUSER/Library/Preferences/com.apple.dock.plist

CheckIfADAccount

if [ $AD = "1" ]; then
CheckADUserType
fi

if [ "$ADUser" = "Student" ]; then
	runAsUser osascript -e 'display alert "Please wait while we set up your profile."'
	
	CheckStudentFolderPath
    
	echo "Home Folder is $MYHOMEDIR" >> /tmp/LibrarySync.log 
	echo "Home Folder is $MYHOMEDIR"


    if [ ! -d "$MYHOMEDIR/Library/Preferences" ]; then
    	CreateHomeLibraryFolders
        echo "Creating Library template" >> /tmp/LibrarySync.log 
		echo "Creating Library template"
    else
        echo "Home Library exists already" >> /tmp/LibrarySync.log 
		echo "Home Library exists already"
    fi

	RedirectIfADAccount
       
	# Pin redirected folders
    if [ -f /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.PinFolders.plist ] ; then
      	Echo "Redirected folders already pinned"
   else
  	    if [ -f /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.RedirectedFolders.plist ] ; then
			echo "Pinning folders to sidebar" >> /tmp/LibrarySync.log 
			echo "Pinning folders to sidebar"
           	PinRedirectedFolders
        fi
	fi
 
   if [ ! -d /Users/$CurrentUSER/Documents/Sync ]; then 
      CreateDocumentlibraryfolders
   fi
  
   if [ ! -d /Users/$CurrentUSER/Library/Application\ Support/Google/Chrome/Profile\ 1  ]; then 
      PreStageUnlinkedAppFolders
   fi

   linklibraryfolders
  
   # Sync User's Home Library with local library.
   SyncHomeLibraryToLocal
       
   linktwinefolders
   
    sleep 5
    
   fixLibraryPerms &
 
   CopyRoamingAppFiles
	
	runAsUser osascript -e 'display alert "You are good to go. Thank you for waiting"'
# Finish configuration of Student AD account
fi


if [ "$ADUser" = "Staff" ]; then
    runAsUser osascript -e 'display alert "Please wait while we set up your profile."'
	
    CheckStaffFolderPath
    echo "Home Folder is $MYHOMEDIR" >> /tmp/LibrarySync.log 
	echo "Home Folder is $MYHOMEDIR"

    
    RedirectIfADAccount
        
	# Pin redirected folders
    
    if [ -f /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.PinFolders.plist ] ; then
      	Echo "Redirected folders already pinned"
    else
   	    if [ -f /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.RedirectedFolders.plist ] ; then
			echo "Pinning folders to sidebar" >> /tmp/LibrarySync.log 
			echo "Pinning folders to sidebar"
           	PinRedirectedFolders
        fi
    fi
  
    sleep 5
	runAsUser osascript -e 'display alert "You are good to go. Thank you for waiting"'
    
# Finish configuration of Staff AD account
fi

# Start the library sync back to home
echo "`date` - Start sync back to home for $CurrentUSER" >> /tmp/LibrarySync.log 
echo "`date` - Start sync back to home for $CurrentUSER"

#jamf policy -event synctohome &&

if [ "$ADUser" = "Student" ]; then
trap OnExit exit
fi
exit 0

