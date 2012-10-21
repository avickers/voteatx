require 'findit'

module FindIt
  module Feature
    module Travis_CO_TX_US      

      # Factory class for the application to obtain voting place information.
      #
      # These classes load data from an external file, using the
      # FindIt::Feature::Travis_CO_TX_US::VotingPlaceData class,
      # which must recognize the "election" parameter passed to
      # the factory methods.
      #
      class VotingPlaceFactory
        
        # Construct a concrete instance of FindIt::Feature::Travis_CO_TX_US::AbstractEdayVotingPlace.
        #
        # Parameters:
        # * db -- A handle to the database that has electron district geospatial data.
        # * election -- The election identifier.
        #
        def self.create_eday_voting_place(db, election)          
          klass = Class.new(AbstractEdayVotingPlace)
          klass.instance_variable_set(:@db, db)
          klass.instance_variable_set(:@election, election)
          klass
        end

        # Construct a concrete instance of FindIt::Feature::Travis_CO_TX_US::AbstractEarlyVotingPlace.
        #
        # Parameters:
        # * db -- A handle to the database that has voting place geospatial data.
        # * election -- The election identifier.
        #
        def self.create_early_voting_place(db, election)          
          klass = Class.new(AbstractEarlyVotingPlace)
          klass.instance_variable_set(:@db, db)
          klass.instance_variable_set(:@election, election)
          klass
        end
      
      end  # class VotingPlaceFactory
      
      
      # Derived class from FindIt::BaseFeature, representing an election day voting place.
      #
      class AbstractEdayVotingPlace < FindIt::BaseFeature    
        
        # class instance variables will be initialized by factory method
        @db = nil
        @election = nil        
        
        # Return the voting place that is closest to the given location.
        #
        def self.closest(origin)
          
          # Find the voting precinct that contains the origin point.
          district = @db[:travis_co_tx_us_voting_districts] \
            .select(:p_vtd) \
            .filter{ST_Contains(:geometry, ST_Transform(MakePoint(origin.lng, origin.lat, 4326), 3081))} \
            .fetch_one
          return nil unless district
          precinct = district[:P_VTD].to_i
            
          # Find the voting place for this precinct.
          place = @db[:travis_co_tx_us_voting_eday_places] \
            .select_all(:travis_co_tx_us_voting_eday_places, :travis_co_tx_us_voting_locations) \
            .join(:travis_co_tx_us_voting_locations, :id => :location_id) \
            .filter(:precinct => precinct) \
            .fetch_one
          raise "cannot find election day voting place for precinct \"#{precinct}\"" unless place
          raise "cannot find election day voting location for precinct \"#{precinct}\"" unless place[:geometry]
          
          # TODO - select an alternate marker if the voting place is open now
          marker = FindIt::Asset::MapMarker.new("/mapicons/vote_icon.png", :shadow => "vote_icon_shadow.png")

          new(FindIt::Location.from_geometry(@db, place[:geometry]),
            :title => "Your voting place (precinct #{precinct})",
            :name => place[:name],
            :address => place[:street],
            :city => place[:city],
            :state => place[:state],
            :zip => place[:zip],
            :link => place[:link],
            :note => place[:notes],
            :origin => origin,      
            :marker => marker)
        end        

        attr_reader :marker
        
        def initialize(location, params = {})
          super
          @marker = params[:marker]
        end
  
        def self.type
          :ELECTION_VOTING_PLACE
        end
          
        def marker
          @marker
        end
      end # class AbstractEdayVotingPlace
      
      
      # Derived class from FindIt::BaseFeature, representing early voting places.
      #
      class AbstractEarlyVotingPlace < FindIt::BaseFeature
        
        # class instance variables will be initialized by factory method
        @db = nil
        @election = nil  
        
        # Return a list of early voting places for this given location.
        #
        # The list will contain the closest fixed early voting place
        # that is closest to this location, plus zero or more selected
        # mobile early voting locations.
        #
        # The selected mobile early voting locations will all be:
        # 1) closer to the specified location than the nearest fixed
        # early voting location, and 2) has not finally closed for
        # this election.
        #
        def self.closest(origin)
            
          fixed = @db[:travis_co_tx_us_voting_evfixed_places] \
              .select_all(:travis_co_tx_us_voting_evfixed_places, :travis_co_tx_us_voting_locations) \
              .select_append{ST_Distance(geometry, MakePoint(origin.lng, origin.lat, 4326)).as(:dist)} \
              .join(:travis_co_tx_us_voting_locations, :id => :location_id) \
              .order(:dist.asc) \
              .first
              
          raise "no fixed early voting places" unless fixed
          raise "cannot find location for early voting place id #{fixed[:id]}" unless fixed[:geometry]         

          # TODO - select an alternate marker if the voting place is open now
          marker = FindIt::Asset::MapMarker.new("/mapicons/vote_early_icon.png", :shadow => "vote_icon_shadow.png")

          ret = []
          ret << new(FindIt::Location.from_geometry(@db, fixed[:geometry]),
            :ev_type => :EVFIXED,
            :title => "Early voting location",
            :name => fixed[:name],
            :address => fixed[:street],
            :city => fixed[:city],
            :state => fixed[:state],
            :zip => fixed[:zip],
            :link => fixed[:link],
            :note => fixed[:notes],
            :origin => origin,
            :marker => marker)
              
          mobiles = @db[:travis_co_tx_us_voting_evmobile_places] \
            .select_all(:travis_co_tx_us_voting_evmobile_places, :travis_co_tx_us_voting_locations) \
            .select_append{ST_Distance(geometry, MakePoint(origin.lng, origin.lat, 4326)).as(:dist)} \
            .select_append{((opens > Time.now) & (closes < Time.now)).as(:open_now)} \
            .distinct \
            .join(:travis_co_tx_us_voting_locations, :id => :travis_co_tx_us_voting_evmobile_places__location_id) \
            .join(:travis_co_tx_us_voting_evmobile_schedules, :place_id => :travis_co_tx_us_voting_evmobile_places__id) \
            .filter{dist < fixed[:dist]} \
            .filter{closes > Time.now} \
            .order(:opens.asc, :dist.asc) \
            .limit(3) \
            .all
            
          mobiles.each do |p|  
  
            # TODO - select an alternate marker if the voting place is open now
            marker = FindIt::Asset::MapMarker.new("/mapicons/vote_mobile_icon.png", :shadow => "vote_icon_shadow.png")

            ret << new(FindIt::Location.from_geometry(@db, p[:geometry]),
              :ev_type => :EVMOBILE,
              :title => "Mobile early voting location",
              :name => p[:name],
              :address => p[:street],
              :city => p[:city],
              :state => p[:state],
              :zip => p[:zip],
              :link => p[:link],
              :note => p[:notes],
              :origin => origin,
              :marker => marker)
          end
                     
          ret           
        end
        
        attr_reader :marker
        
        def initialize(location, params = {})
          super
          @marker = params[:marker]
        end
  
        def self.type
          :EARLY_VOTING_PLACE
        end
          
        def marker
          @marker
        end
           
        
#        # Select the appropriate marker for this voting place.
#        #
#        # Chooses between two icons to distinguish between
#        # fixed and mobile locations.
#        #
#        def marker
#          case @ev_type
#          when :EVFIXED
#            icon = "/mapicons/vote_early_icon.png"
#          when :EVMOBILE
#            icon = "/mapicons/vote_mobile_icon.png"
#          else
#            raise "unknown EarlyVotingPlace type \"#{@ev_type}\""
#          end
#          FindIt::Asset::MapMarker.new(icon, :shadow => "vote_icon_shadow.png")
#        end
      
      end # class AbstractEarlyVotingPlace

    end # module Travis_CO_TX_US
  end # module Feature
end # module FindIt
